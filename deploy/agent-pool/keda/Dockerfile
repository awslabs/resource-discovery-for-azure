# Azure DevOps self-hosted agent image for the KEDA-scaled AKS pool, on a
# Red Hat UBI 9 base (matches a common enterprise RHEL toolchain; UBI is free to use).
#
# The RDA code is NOT baked in - the pipeline's `checkout: self` brings it onto
# the agent at run time. This image only needs: the ADO agent bootstrap
# (start.sh) plus the tooling the RDA step requires, because AzurePowerShell@5
# on a SELF-HOSTED agent does NOT install Az - it must already be present:
#   - PowerShell 7 (pwsh)
#   - the Az submodules RDA uses (Accounts/Compute/Monitor/Billing/ResourceGraph),
#     plus Az.Storage for the -UploadToBlobContainerUri blob upload
#   - az CLI (parity with a typical enterprise toolchain)
FROM registry.access.redhat.com/ubi9/ubi:latest

# Agent + RDA runtime dependencies.
RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc \
 && curl -sSL -o /etc/yum.repos.d/microsoft-prod.repo https://packages.microsoft.com/config/rhel/9/prod.repo \
 && dnf install -y powershell azure-cli libicu jq git tar which findutils \
 && dnf clean all

# Az PowerShell submodules RDA depends on (installed once, machine-wide).
# Az.Storage is required by -UploadToBlobContainerUri (report/support-log upload).
RUN pwsh -NoProfile -Command "Install-Module -Name Az.Accounts,Az.Compute,Az.Monitor,Az.Billing,Az.ResourceGraph,Az.Storage -Repository PSGallery -Scope AllUsers -Force -AllowClobber"

# The Azure DevOps agent's config.sh/run.sh refuse to run as root ("Must not
# run with sudo") unless this is set. The container runs as root, so allow it.
ENV AGENT_ALLOW_RUNASROOT="1"

WORKDIR /azp
COPY start.sh /azp/start.sh
RUN chmod +x /azp/start.sh

ENTRYPOINT ["/azp/start.sh"]
