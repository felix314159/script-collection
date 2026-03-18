#!/usr/bin/env bash

set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import json
import sys
from datetime import datetime
from html import unescape
from html.parser import HTMLParser
from itertools import islice
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import Request, urlopen


DEFAULT_BATCH_SIZE = 100
DEFAULT_TIMEOUT_SECONDS = 30
USER_AGENT = "magicians-get.sh/1.0 (+https://ethereum-magicians.org)"
POST_FIELDS = (
    "username",
    "created_at",
    "post_number",
    "upvotes",
    "link_counts",
    "post_url",
    "content",
)
THREAD_FIELDS = (
    "title",
    "posts_count",
    "created_at",
    "views",
    "like_count",
)
TOPIC_LINK_FIELDS_TO_REMOVE = {
    "user_id",
    "domain",
    "root_domain",
    "internal",
    "reflection",
}
FIELDS_TO_REMOVE_GLOBALLY = {"bookmarks"}
TOP_LEVEL_TOPIC_FIELDS_TO_REMOVE = {
    "actions_summary",
    "archetype",
    "category_id",
    "chunk_size",
    "current_post_number",
    "details",
    "discourse_zendesk_plugin_zendesk_url",
    "draft_key",
    "fancy_title",
    "highest_post_number",
    "id",
    "message_bus_last_id",
    "slow_mode_seconds",
    "slug",
    "suggested_topics",
    "tags",
    "tags_descriptions",
    "timeline_lookup",
    "visible",
    "vote_count",
    "word_count",
}
POST_STREAM_FIELDS_TO_REMOVE = {"stream"}


class HTMLTextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.parts: list[str] = []
        self.onebox_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        attrs_dict = dict(attrs)
        classes = set(attrs_dict.get("class", "").split())

        if tag == "aside" and "onebox" in classes:
            source_url = attrs_dict.get("data-onebox-src")
            if source_url:
                self.parts.append(f"\n\n{source_url}\n\n")
            self.onebox_depth = 1
            return

        if self.onebox_depth:
            self.onebox_depth += 1
            return

        if tag in {"br", "hr"}:
            self.parts.append("\n")
        elif tag in {"p", "div", "section", "article", "aside", "blockquote"}:
            self.parts.append("\n\n")
        elif tag in {"li"}:
            self.parts.append("\n- ")

    def handle_endtag(self, tag: str) -> None:
        if self.onebox_depth:
            self.onebox_depth -= 1
            return

        if tag in {"p", "div", "section", "article", "aside", "blockquote"}:
            self.parts.append("\n\n")

    def handle_data(self, data: str) -> None:
        if self.onebox_depth:
            return
        self.parts.append(data)

    def handle_entityref(self, name: str) -> None:
        if self.onebox_depth:
            return
        self.parts.append(f"&{name};")

    def handle_charref(self, name: str) -> None:
        if self.onebox_depth:
            return
        self.parts.append(f"&#{name};")

    def get_text(self) -> str:
        text = unescape("".join(self.parts))
        lines = [line.strip() for line in text.splitlines()]
        normalized = "\n".join(line for line in lines)
        paragraphs = [paragraph.strip() for paragraph in normalized.split("\n\n")]
        return "\n\n".join(paragraph for paragraph in paragraphs if paragraph).strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Download a Discourse topic, including all posts and topic metadata, "
            "as a single JSON object."
        )
    )
    parser.add_argument(
        "topic_url",
        help=(
            "Discourse topic URL, for example "
            "https://ethereum-magicians.org/t/eip-7805-.../21578"
        ),
    )
    parser.add_argument(
        "-o",
        "--output",
        help="Write the merged JSON object to this file instead of stdout.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help="How many missing post IDs to request per batch. Default: %(default)s.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="HTTP timeout in seconds. Default: %(default)s.",
    )
    args = parser.parse_args()
    if args.batch_size < 1:
        parser.error("--batch-size must be greater than 0")
    if args.timeout < 1:
        parser.error("--timeout must be greater than 0")
    return args


def batched(values: list[int], size: int):
    iterator = iter(values)
    while batch := list(islice(iterator, size)):
        yield batch


def normalize_topic_urls(topic_url: str) -> tuple[str, str, int]:
    parsed = urlsplit(topic_url)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError(f"Expected an absolute topic URL, got: {topic_url}")

    parts = [part for part in parsed.path.split("/") if part]
    if not parts or parts[0] != "t":
        raise ValueError(f"URL does not look like a Discourse topic: {topic_url}")

    topic_id = None
    for part in parts[1:]:
        if part.endswith(".json"):
            part = part[:-5]
        if part.isdigit():
            topic_id = int(part)
            break

    if topic_id is None:
        raise ValueError(f"Could not determine the topic ID from: {topic_url}")

    base_url = f"{parsed.scheme}://{parsed.netloc}"
    canonical_topic_url = f"{base_url}/t/{topic_id}"
    topic_json_url = f"{canonical_topic_url}.json"
    return canonical_topic_url, topic_json_url, topic_id


def fetch_json(url: str, *, timeout: int) -> dict:
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(request, timeout=timeout) as response:
        return json.load(response)


def html_to_text(html: str) -> str:
    parser = HTMLTextExtractor()
    parser.feed(html)
    parser.close()
    return parser.get_text()


def extract_upvotes(post: dict) -> int:
    actions_summary = post.get("actions_summary")
    if not isinstance(actions_summary, list):
        return 0

    for action in actions_summary:
        if not isinstance(action, dict):
            continue
        if action.get("id") == 2:
            count = action.get("count")
            if isinstance(count, int):
                return count
            break

    return 0


def enrich_post(post: dict, *, base_url: str) -> dict:
    cooked = post.get("cooked")
    content = ""
    if isinstance(cooked, str):
        content = html_to_text(cooked)

    reduced_post = {field: post.get(field) for field in POST_FIELDS}
    post_url = reduced_post.get("post_url")
    if isinstance(post_url, str):
        reduced_post["post_url"] = urljoin(base_url, post_url)
    reduced_post["upvotes"] = extract_upvotes(post)
    reduced_post["content"] = content
    return reduced_post


def merge_all_posts(topic: dict, *, canonical_topic_url: str, timeout: int, batch_size: int):
    stream_ids = topic.get("post_stream", {}).get("stream", [])
    if not stream_ids:
        return [], []

    posts_by_id = {
        post["id"]: enrich_post(post, base_url=canonical_topic_url)
        for post in topic.get("post_stream", {}).get("posts", [])
    }
    missing_ids = [post_id for post_id in stream_ids if post_id not in posts_by_id]

    for batch in batched(missing_ids, batch_size):
        query = urlencode([("post_ids[]", post_id) for post_id in batch])
        batch_url = f"{canonical_topic_url}/posts.json?{query}"
        batch_data = fetch_json(batch_url, timeout=timeout)
        for post in batch_data.get("post_stream", {}).get("posts", []):
            posts_by_id[post["id"]] = enrich_post(post, base_url=canonical_topic_url)

    ordered_posts = [posts_by_id[post_id] for post_id in stream_ids if post_id in posts_by_id]
    unresolved_ids = [post_id for post_id in stream_ids if post_id not in posts_by_id]
    topic["post_stream"]["posts"] = ordered_posts
    return ordered_posts, unresolved_ids


def dump_result(result: dict, *, output: str | None, stream=None) -> None:
    json_kwargs = {"sort_keys": False, "ensure_ascii": False, "indent": 2}

    if output:
        output_path = Path(output)
        output_path.write_text(json.dumps(result, **json_kwargs) + "\n", encoding="utf-8")
        return

    target = sys.stdout if stream is None else stream
    json.dump(result, target, **json_kwargs)
    target.write("\n")


def format_datetime_value(value: str) -> str:
    normalized = value.replace("Z", "+00:00")
    dt = datetime.fromisoformat(normalized).astimezone()
    return dt.strftime("%Y-%m-%d, %I:%M %p")


def format_datetime_fields(value):
    if isinstance(value, dict):
        formatted = {}
        for key, item in value.items():
            if (key.endswith("_at") or key == "last_thread_activity") and isinstance(
                item, str
            ):
                try:
                    formatted[key] = format_datetime_value(item)
                    continue
                except ValueError:
                    pass
            formatted[key] = format_datetime_fields(item)
        return formatted

    if isinstance(value, list):
        return [format_datetime_fields(item) for item in value]

    return value


def prune_null_and_false(value):
    if isinstance(value, dict):
        pruned = {}
        for key, item in value.items():
            if key in FIELDS_TO_REMOVE_GLOBALLY:
                continue
            if item is None or item is False:
                continue
            pruned[key] = prune_null_and_false(item)
        return pruned

    if isinstance(value, list):
        return [prune_null_and_false(item) for item in value]

    return value


def prune_topic_links(topic: dict) -> dict:
    details = topic.get("details")
    if not isinstance(details, dict):
        return topic

    links = details.get("links")
    if not isinstance(links, list):
        return topic

    pruned_links = []
    for link in links:
        if not isinstance(link, dict):
            pruned_links.append(link)
            continue
        pruned_links.append(
            {
                key: value
                for key, value in link.items()
                if key not in TOPIC_LINK_FIELDS_TO_REMOVE
            }
        )
    details["links"] = pruned_links
    return topic


def prune_topic_fields(topic: dict) -> dict:
    for field in TOP_LEVEL_TOPIC_FIELDS_TO_REMOVE:
        topic.pop(field, None)

    post_stream = topic.get("post_stream")
    if isinstance(post_stream, dict):
        for field in POST_STREAM_FIELDS_TO_REMOVE:
            post_stream.pop(field, None)

    return topic


def extract_topic_username(topic: dict) -> str | None:
    details = topic.get("details")
    if isinstance(details, dict):
        created_by = details.get("created_by")
        if isinstance(created_by, dict):
            username = created_by.get("username")
            if isinstance(username, str):
                return username

    posts = topic.get("post_stream", {}).get("posts", [])
    if posts and isinstance(posts[0], dict):
        username = posts[0].get("username")
        if isinstance(username, str):
            return username

    return None


def build_user_participation(topic: dict, *, creator_username: str | None) -> list[str]:
    usernames: list[str] = []
    seen: set[str] = set()

    if creator_username:
        usernames.append(creator_username)
        seen.add(creator_username)

    posts = topic.get("post_stream", {}).get("posts", [])
    for post in posts:
        if not isinstance(post, dict):
            continue
        username = post.get("username")
        if isinstance(username, str) and username not in seen:
            usernames.append(username)
            seen.add(username)

    return usernames


def main() -> int:
    args = parse_args()

    try:
        canonical_topic_url, topic_json_url, _topic_id = normalize_topic_urls(args.topic_url)
        topic = fetch_json(topic_json_url, timeout=args.timeout)
        posts, unresolved_ids = merge_all_posts(
            topic,
            canonical_topic_url=canonical_topic_url,
            timeout=args.timeout,
            batch_size=args.batch_size,
        )
        topic = prune_topic_links(topic)
        topic = prune_topic_fields(topic)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except HTTPError as exc:
        print(f"error: HTTP {exc.code} while fetching {exc.url}", file=sys.stderr)
        return 1
    except URLError as exc:
        print(f"error: failed to reach {args.topic_url}: {exc.reason}", file=sys.stderr)
        return 1

    if unresolved_ids:
        error_result = {
            "error": "incomplete_topic_fetch",
            "message": "Failed to fetch every post in the topic.",
            "requested_url": args.topic_url,
            "missing_post_ids": unresolved_ids,
            "posts_returned": len(posts),
            "expected_post_count": len(posts) + len(unresolved_ids),
            "debug": {
                "topic_json_url": topic_json_url,
                "batch_size": args.batch_size,
                "timeout_seconds": args.timeout,
            },
        }
        error_result = format_datetime_fields(error_result)
        error_result = prune_null_and_false(error_result)
        dump_result(error_result, output=None, stream=sys.stderr)
        return 1

    creator_username = extract_topic_username(topic)

    result = {
        "requested_url": args.topic_url,
        "posts_returned": len(posts),
        **{field: topic.get(field) for field in THREAD_FIELDS},
        "last_thread_activity": topic.get("last_posted_at"),
        "thread_creator": creator_username,
        "user_participation_count": topic.get("participant_count"),
        "user_participation": build_user_participation(
            topic, creator_username=creator_username
        ),
        "replies": topic.get("post_stream", {}).get("posts", []),
    }
    result = format_datetime_fields(result)
    result = prune_null_and_false(result)
    dump_result(result, output=args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
