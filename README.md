# smarli. Blueprints

This repository holds the released Home Assistant blueprints of smarli. AG. A workflow writes every file here. Nobody edits this repository by hand.

- `automation/` holds one file per blueprint. The file on `main` is always the newest released version.
- A file is never deleted, so "Re-import blueprint" in Home Assistant keeps working.
- Each commit names the blueprints it released and their versions.

## Import a blueprint

In Home Assistant, go to **Settings → Automations & scenes → Blueprints → Import blueprint**. Use the GitHub address of the file, for example:

```
https://github.com/smarli-AG/smarli-blueprints/blob/main/automation/allOff_smarliRelay.yaml
```

The blueprints need the smarli. packages, which every smarli.-managed hub has.

## Issues and pull requests

This repository does not take issues or pull requests. Development happens in a private repository.
