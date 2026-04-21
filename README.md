# script-collection
Random helper scripts that might be useful to someone out there

## Scripts Purpose

### sh (might contain or be almost fully py)
* `cifail.sh`: Give it any job URL and it will download the logs of all failed CI runs locally for efficient LLM consumption.
* `find_long_py.sh`: List the longest .py files in any subdir descending by lines. Only shows files with 800+ lines.
* `ghact.sh`: Get overview of anyone's recent github activity in any repo. E.g. `./ghact.sh ethereum/execution-specs,ethereum/hive felix314159,spencer-tb 5` shows all commits made by `felix314159` or `spencer-tb` in the repos `ethereum/execution-specs` or `ethereum/hive` within the past `5` hours
* `gitcompare.sh`: Compare current local branch (latest commit hash) with remote branch of same name. If you do not specify the remote branch name it will default to comparing to 'eels'. If the chosen remote does not exist you are warned. If it does exist it either prints `OK (commithash, date)` when hashes match, otherwise it will print `NOT SYNCED` and provide the commit hashes and dates for both branches you are comparing.
* `magicians-fetchThread.sh`: Download entire ETH Magicians Thread with subset of relevant metadata for human/LLM consumption
* `prcommits.sh`: Get a list of all commits that exist in a given PR URL and get insurance that you locally access them (useful for building LLM skill around this for accessing changes of any PR URL. For then actually accessing the changes your LLM should not `git` not the github api)
* `prreview.sh`: Give it any Github PR URL and it will create a JSON object that contains all context an LLM needs (who commented what where, who wants which modifications to which files, etc)

### py
* `refspecfind.py`: This helper script is specific to the [execution-specs repo](https://github.com/ethereum/execution-specs). It helps to keep track of an EIP development branch and the respective [EIPs repo](https://github.com/ethereum/EIPs/tree/master/EIPS) branch so that it is clear how up-to-date the current test cases are. Hash mismatch here usually means there was a specs update (in EIPs repo) but the EELS implementation of this has not been done merged yet.
* `unicode-detector.py`: Detects any unicode symbols in any file. Supports customization (e.g. excluded dirs, allowed unicode chars) and provides statistics at the end. Ideally paired with a GitHub action that runs against all files modified in any commit of the current PR. Why this is useful: glassworm is a documented, real-world attack where attackers use invisible unicode that looks like an empty string to run malicious code. another malicious thing would be invisible LLM prompts that make use of jailbreaks, when any LLM scans such invisible chars it could be convinced to perform malicious actions. Given that reviewing an invisible threat without such a helper script would be nearly impossible, it felt like a useful script to have
