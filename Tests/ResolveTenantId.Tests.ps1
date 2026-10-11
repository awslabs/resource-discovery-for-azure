# Offline unit tests for Resolve-TenantId in Functions/RunAllSubscriptions.Functions.ps1.
# Covers the three input forms the wrapper accepts for -TenantID: a GUID (returned
# unchanged, no network call), a domain name (resolved to its tenant GUID via OIDC
# discovery), and an email / UPN (its domain is extracted, then resolved the same
# way). Invoke-RestMethod is mocked, so these tests make NO network call and are
# deterministic on any host.

BeforeAll {
    $script:FunctionsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/RunAllSubscriptions.Functions.ps1'
    if (-not (Test-Path $script:FunctionsPath))
    {
        throw "Could not find shared functions file at $script:FunctionsPath"
    }
    . $script:FunctionsPath

    # Guard: fail loudly here if the function is renamed or removed, rather than
    # with a confusing "command not found" mid-test.
    if (-not (Get-Command 'Resolve-TenantId' -CommandType Function -ErrorAction SilentlyContinue))
    {
        throw "Expected function 'Resolve-TenantId' to be defined by $script:FunctionsPath, but it was not. Has it been renamed or removed?"
    }

    # A representative tenant GUID and the OIDC issuer that discovery returns for it.
    # The repo's standard dummy GUID - the issuer is mocked, so any well-formed GUID works.
    $script:TenantGuid = '12345678-1234-1234-1234-123456789012'
    $script:IssuerFor = { param($Guid) [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$Guid/v2.0" } }
}

Describe 'Resolve-TenantId' {

    Context 'GUID passthrough' {

        It 'returns a GUID unchanged and makes no network call' {
            Mock Invoke-RestMethod { throw 'Invoke-RestMethod must not be called for a GUID input' }
            $Result = Resolve-TenantId -Value $script:TenantGuid
            $Result | Should -Be $script:TenantGuid
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }

    Context 'domain resolution' {

        It 'resolves a domain name to the tenant GUID from the OIDC issuer' {
            Mock Invoke-RestMethod { & $script:IssuerFor $script:TenantGuid }
            $Result = Resolve-TenantId -Value 'contoso.onmicrosoft.com'
            $Result | Should -Be $script:TenantGuid
            Should -Invoke Invoke-RestMethod -Times 1
        }

        It 'queries the OIDC endpoint with the domain itself as the tenant path segment' {
            Mock Invoke-RestMethod { & $script:IssuerFor $script:TenantGuid } `
                -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/contoso.com/v2.0/.well-known/openid-configuration' }
            $Result = Resolve-TenantId -Value 'contoso.com'
            $Result | Should -Be $script:TenantGuid
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/contoso.com/v2.0/.well-known/openid-configuration' }
        }
    }

    Context 'email-to-domain extraction' {

        It 'extracts the domain from an email and resolves THAT, not the raw email' {
            # The OIDC endpoint rejects a raw UPN (user@domain) with HTTP 400, so the
            # function must query the domain after the '@'. Assert the mock is hit
            # with the domain-only URL (never the full email).
            Mock Invoke-RestMethod { & $script:IssuerFor $script:TenantGuid } `
                -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/contoso.com/v2.0/.well-known/openid-configuration' }
            $Result = Resolve-TenantId -Value 'alice@contoso.com'
            $Result | Should -Be $script:TenantGuid
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/contoso.com/v2.0/.well-known/openid-configuration' }
        }

        It 'never queries the OIDC endpoint with the raw email in the path' {
            Mock Invoke-RestMethod { & $script:IssuerFor $script:TenantGuid }
            $null = Resolve-TenantId -Value 'first.last@contoso.onmicrosoft.com'
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like '*first.last@*' }
        }

        It 'handles an email whose local part contains dots' {
            Mock Invoke-RestMethod { & $script:IssuerFor $script:TenantGuid } `
                -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0/.well-known/openid-configuration' }
            $Result = Resolve-TenantId -Value 'first.last@contoso.onmicrosoft.com'
            $Result | Should -Be $script:TenantGuid
            Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0/.well-known/openid-configuration' }
        }
    }

    Context 'resolution failures' {

        It 'throws a clear error when OIDC discovery fails' {
            Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 400 (Bad Request).' }
            { Resolve-TenantId -Value 'not-a-real-domain.example' } |
                Should -Throw -ExpectedMessage "*Could not resolve tenant 'not-a-real-domain.example'*"
        }

        It 'throws when the issuer carries no recognizable tenant GUID' {
            Mock Invoke-RestMethod { [pscustomobject]@{ issuer = 'https://login.microsoftonline.com/common/v2.0' } }
            { Resolve-TenantId -Value 'contoso.com' } | Should -Throw -ExpectedMessage '*did not contain a recognizable tenant GUID*'
        }
    }
}
