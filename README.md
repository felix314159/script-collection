# script-collection
Random helper scripts that might be useful to someone out there

## Scripts Purpose

* `cifail.sh`: Give it any job URL and it will download the logs of all failed CI runs locally for efficient LLM consumption.
* `ghact.sh`: Get overview of anyone's recent github activity in any repo. E.g. `./ghact.sh ethereum/execution-specs felix314159 5` shows all commits made by `felix314159` in the repo `ethereum/execution-specs` within the past `5` hours
* `prcommits.sh`: Get a list of all commits that exist in a given PR URL and get insurance that you locally access them (useful for building LLM skill around this for accessing changes of any PR URL. For then actually accessing the changes your LLM should not `git` not the github api)
* `prreview.sh`: Give it any Github PR URL and it will create a JSON object that contains all context an LLM needs (who commented what where, who wants which modifications to which files, etc)
