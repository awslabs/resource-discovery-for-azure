# Container image for running RDA horizontal shards on Kubernetes/AKS (or any
# container runtime). Build it server-side, from the REPO ROOT as the context,
# with the Azure Container Registry build task:
#
#   az acr build --registry <acr> --image rda:latest --file deploy/Dockerfile .
#
# (or the module-based path shown in docs/horizontal-sharding.md). The trailing
# '.' is the build context = the repo root, so the whole product is copied in.
# .dockerignore (at the repo root) keeps local-only/dev content (.git, .kiro,
# .exploration, Tests, docs, .github) OUT of the image. Version.json IS included
# on purpose - the report header and MainSummary read it.
#
# The base image ships PowerShell 7 + the Az modules, so the pod signs in with
# the Az module (Connect-AzAccount) and needs NO az CLI at runtime.
FROM mcr.microsoft.com/azure-powershell:latest

WORKDIR /rda
COPY . /rda

# The entrypoint derives this pod's shard from the indexed-Job completion index,
# signs in via workload identity, and runs the wrapper for THIS shard only.
ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/rda/deploy/entrypoint.ps1"]
