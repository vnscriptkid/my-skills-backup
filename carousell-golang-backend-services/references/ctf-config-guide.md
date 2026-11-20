# CTF Config Management Guide

## Background info

This system allows us to configure different config values in different environments (eg. prod, staging, feature env).
There is a internal website that allows us to change the config values.

About the `config-template.yml` file:
- This file defines the configuration "schema" for the service.
- Golang structs are generated from this file using the `devctl config codegen` command, eg. `devctl config codegen --config-template-file=config-template.yml --language=go --output=internal/config/types.go`
    - You must NOT edit the generated go file directly, you must use devctl config codegen to regenerate it.
- A default value to use for the initial deployment may be OPTIONALLY defined in this file using a syntax like this:
```
  carousellBaseUrl: !STRING "https://carousell.com"
```
- Never assume the default values in `config-template.yml` are the current values in any environment.

## Config Value Types

Basic data types:
```
STRING
INT
BOOL
FLOAT
JSON
HOSTPORT
SECRET
DURATION
STRING_ARRAY
BOOL_ARRAY
INT_ARRAY
FLOAT_ARRAY
HOSTPORT_ARRAY
```

Composite types (eg. `!GRPC_SERVICE`, `!POSTGRES`) are defined in the private GitHub repo `carousell/config-manager` at `internal/template_processor/standardized-types.yaml` (master branch).

How are the config values read by the backend service:
- During the Github CI deployment pipeline, the current config is fetched and saved to a file placed at `/opt/config/service-name.yml` in the container.
- In golang, there is a company-specific library `github.com/carousell/go-utils/configloader` that is used to parse the rendered config yml file and populate it to the auto-generated config structs.

## How to update the config template

1. Update `config-template.yml`
    - Only set default values if the value is expected to be the same for both prod and staging (dev).
2. Regenerate the config types go file using `devctl config codegen ...`
  - If `make config-codegen` exists, run it
  - Otherwise, search the makefile for any commands beginning with `devctl config codegen` and run that instead
  - If neither of the above exist, STOP and ask the user how to regenerate the go file
3. Validate that the go file was updated
  - Identify the go file expected to be updated. It is inferred from the `devctl config codegen` command: the `--output` flag if it exists, or `> path/to/config/types.go` otherwise.
  - If possible, use `git status` and `git diff` to check the changes. Otherwise, manually check the file for changes.
4. Wire up the new types in the config types Go file to the rest of the codebase.

You MUST NOT update the config types go file by hand.

## Common mistakes

- Use the `!DURATION` type for time durations, never `!INT` (eg. NOT `timeoutMs: !INT`). Existing code makes this mistake; do not copy it.

## How to fetch the current config values

To get prod values: `devctl config load --system=${SERVICE_NAME} --env=prod`

To get stage/staging values: `devctl config load --system=${SERVICE_NAME} --env=staging`

`${SERVICE_NAME}`: see Service name in the main skill.

To get feature env values (the feature env kube context is `gke_carousell-staging_asia-east1-c_staging-feature-k127`):
1. List the pods in the feature env namespace using `kubectl get pods --context gke_carousell-staging_asia-east1-c_staging-feature-k127 --namespace <feature-env-name>` and identify the pod name of the service.
2. Download the config yml file using `kubectl cp <pod name>:/opt/config/ . --context gke_carousell-staging_asia-east1-c_staging-feature-k127 --namespace <feature-env-name>`. The file will be named `service-name.yml`
  - Note: ignore "tar: Removing leading / from member names" warnings

Reminder: no yml file in the repo (`config-template.yml`, `config-migration.yml`, `prod.yml`, etc.) reflects the current config values. Always fetch them as above.

## How to update the current config values

The user needs to do this via the devportal website.
