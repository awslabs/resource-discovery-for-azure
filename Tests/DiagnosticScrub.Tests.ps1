# Protect-DiagnosticText scrub tests
# =============================================================================
# Offline, self-contained tests for the scrub that makes the SHAREABLE (in-zip,
# obfuscated) diagnostics log safe. Protect-DiagnosticText is what stands
# between a raw collector/phase exception message and the Diagnostics_*.log
# that ships in the obfuscated bundle, so these assert - directly, without a
# live run - that every identifier class is masked or tokenized and NONE leaks:
#   - a dictionary-known subscription GUID / resource name / resource group /
#     full ARM id  -> its deterministic prod_/nonprod_ token (via the caller's
#     real-value -> token $ValueMap, applied longest-first)
#   - an UNKNOWN GUID not in the map (e.g. a tenant GUID)  -> '<guid>'
#   - email / UPN            -> '<email>'
#   - IPv4                   -> '<ip>'
#   - Azure data-plane FQDN  -> '<host>'
#   - *nix / Windows home dir-> '<user>'
#   - SAS signature / Bearer -> '<redacted>'
# and that a prod_/nonprod_ token already in the text is left intact.
#
# No customer data: the only literal GUID is the Azure docs placeholder; the
# "unknown tenant" GUID is generated at runtime; every other value is synthetic.
# =============================================================================

BeforeAll {
    $FunctionsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'Functions/ResourceInventory.Functions.ps1'
    if (-not (Test-Path $FunctionsFile)) { throw "ResourceInventory.Functions.ps1 not found at $FunctionsFile" }
    . $FunctionsFile

    # Known (dictionary-backed) real values and their deterministic tokens,
    # mirroring the real-value -> token $diagScrubMap the packaging block builds.
    # All token GUIDs and the secret-shaped fixtures (SAS sig, Bearer JWT) are
    # GENERATED AT RUNTIME so no literal GUID / auth token lives in this source
    # file (only the Azure docs placeholder is a literal GUID) - keeps the file
    # clean for the pre-commit leak scan while still exercising every scrub path.
    $script:SubGuid = '12345678-1234-1234-1234-123456789012'   # Azure docs placeholder
    $script:RgName = 'rg-sensitive-demo'
    $script:ResName = 'vm-app-demo'
    $script:ArmId = "/subscriptions/$script:SubGuid/resourceGroups/$script:RgName/providers/Microsoft.Compute/virtualMachines/$script:ResName"

    $script:SubToken = 'prod_' + [guid]::NewGuid().ToString()
    $script:RgToken = 'nonprod_' + [guid]::NewGuid().ToString()
    $script:NameToken = 'prod_' + [guid]::NewGuid().ToString()
    $script:IdToken = 'prod_' + [guid]::NewGuid().ToString()

    $script:Map = @{
        $script:ArmId   = $script:IdToken
        $script:ResName = $script:NameToken
        $script:RgName  = $script:RgToken
        $script:SubGuid = $script:SubToken
    }

    # A GUID the map has never seen (models a tenant GUID in an ARM error).
    $script:UnknownGuid = [guid]::NewGuid().ToString()

    # Random alphanumeric helper so the secret-shaped fixtures are built at
    # runtime (never a literal secret in source).
    $NewRand = { param($n) -join (1..$n | ForEach-Object { '{0:x}' -f (Get-Random -Minimum 0 -Maximum 16) }) }

    # Synthetic identifiers of every class, embedded in one message.
    $script:Email = 'ops.admin@contoso-corp.com'
    $script:Fqdn = 'appdatastore.blob.core.windows.net'
    $script:Ip = '10.42.13.99'
    $script:HomeNix = '/home/testuser/inventory/run.log'
    $script:HomeWin = 'C:\Users\testuser\inventory\run.log'
    # SAS signature + Bearer JWT assembled from runtime-random parts, so the
    # secret-shaped literal never appears in this file but the scrub's sig=/Bearer
    # rules still fire. Keep the sig/jwt values to assert they are gone afterward.
    $script:SigValue = (& $NewRand 32)
    $script:SasUrl = 'https://example-host/container/blob?sv=2021-08-06&ss=b&' + 'sig=' + $script:SigValue
    # Non-sig query-param forms from the SAME shared auth alternation
    # (sig|signature|sas|accesstoken|...). The sig= assertion only catches a
    # wholesale regex break; these catch the removal of a single alternative
    # (e.g. signature= or sas=) that would otherwise ship untested. Values are
    # runtime-random like the sig fixture, so no literal secret lives in source.
    $script:SignatureValue = (& $NewRand 32)
    $script:SasValue = (& $NewRand 24)
    $script:JwtValue = 'eyJ' + (& $NewRand 12) + '.' + (& $NewRand 16) + '.' + (& $NewRand 16)
    $script:Bearer = 'Bearer ' + $script:JwtValue

    $script:RawMessage = @(
        "Collector 'Streamanalytics' failed for $script:ArmId",
        "(subscription $script:SubGuid, resourceGroup $script:RgName, resource $script:ResName);",
        "tenant $script:UnknownGuid;",
        "contact $script:Email;",
        "host $script:Fqdn ($script:Ip);",
        "log $script:HomeNix / $script:HomeWin;",
        "download $script:SasUrl;",
        "sas params: signature=$script:SignatureValue sas=$script:SasValue;",
        "auth: $script:Bearer"
    ) -join ' '

    $script:Scrubbed = Protect-DiagnosticText $script:RawMessage $script:Map
}

Describe "Protect-DiagnosticText masks dictionary-known identifiers" {

    It "tokenizes the full ARM resource id" {
        $script:Scrubbed | Should -Match ([regex]::Escape($script:IdToken))
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:ArmId))
    }

    It "tokenizes the bare resource group name" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:RgName))
        $script:Scrubbed | Should -Match ([regex]::Escape($script:RgToken))
    }

    It "tokenizes the bare resource name" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:ResName))
        $script:Scrubbed | Should -Match ([regex]::Escape($script:NameToken))
    }

    It "removes the real subscription GUID entirely (tokenized or masked)" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:SubGuid))
    }
}

Describe "Protect-DiagnosticText masks structured identifier classes" {

    It "masks an UNKNOWN GUID (not in the map) as <guid>" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:UnknownGuid))
        $script:Scrubbed | Should -Match '<guid>'
    }

    It "masks email addresses and cannot trip the Obfuscation email scan" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:Email))
        # Same pattern Tests/Obfuscation.Tests.ps1 uses.
        $script:Scrubbed | Should -Not -Match '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
    }

    It "masks IPv4 addresses" {
        $script:Scrubbed | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
    }

    It "masks Azure data-plane FQDNs" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:Fqdn))
    }

    It "masks Unix home paths and cannot trip the Obfuscation home-path scan" {
        $script:Scrubbed | Should -Not -Match '/home/[a-zA-Z]'
    }

    It "masks Windows user paths and cannot trip the Obfuscation home-path scan" {
        $script:Scrubbed | Should -Not -Match 'C:\\Users\\[a-zA-Z]'
    }

    It "redacts a SAS signature value" {
        $script:Scrubbed | Should -Not -Match ('sig=' + [regex]::Escape($script:SigValue))
        $script:Scrubbed | Should -Match 'sig=<redacted>'
    }

    It "redacts a 'signature=' query-param value" {
        $script:Scrubbed | Should -Not -Match ('signature=' + [regex]::Escape($script:SignatureValue))
        $script:Scrubbed | Should -Match 'signature=<redacted>'
    }

    It "redacts a 'sas=' query-param value" {
        $script:Scrubbed | Should -Not -Match ('sas=' + [regex]::Escape($script:SasValue))
        $script:Scrubbed | Should -Match 'sas=<redacted>'
    }

    It "redacts a Bearer token" {
        $script:Scrubbed | Should -Not -Match ([regex]::Escape($script:JwtValue))
        $script:Scrubbed | Should -Match 'Bearer <redacted>'
    }
}

Describe "Protect-DiagnosticText preserves already-obfuscated tokens and edge cases" {

    It "leaves an existing prod_/nonprod_ token intact (GUID safety net does not corrupt it)" {
        # Token built at runtime so no literal GUID lives in this source file.
        $Token = 'prod_' + [guid]::NewGuid().ToString()
        $Out = Protect-DiagnosticText "already masked: $Token" $null
        $Out | Should -Match ([regex]::Escape($Token))
    }

    It "returns null/empty input unchanged" {
        (Protect-DiagnosticText '' $script:Map) | Should -BeNullOrEmpty
        (Protect-DiagnosticText $null $script:Map) | Should -BeNullOrEmpty
    }

    It "works with no map (structured masking still applies)" {
        $Out = Protect-DiagnosticText "tenant $script:UnknownGuid mail $script:Email" $null
        $Out | Should -Not -Match ([regex]::Escape($script:UnknownGuid))
        $Out | Should -Not -Match ([regex]::Escape($script:Email))
    }
}

Describe "Protect-DiagnosticText redacts connection-string secrets while preserving readable segments" {

    # The widened auth alternation now masks the connection-string secret keys
    # Azure storage / Service Bus / SQL / AAD exception text carries, and its
    # value class ([^&;...]) terminates at ';' or '&' so the NEXT segment - and
    # the readable key NAME - survive. Each secret is built at runtime (a fresh
    # GUID 'N' form, like the file's other fixtures) so no literal secret lives
    # in this source and the pre-commit leak scan stays clean.

    It "redacts an AccountKey value while EndpointSuffix survives readable" {
        $Secret = [guid]::NewGuid().ToString('N') + '=='
        $Conn = "AccountName=acct;AccountKey=$Secret;EndpointSuffix=core.windows.net"
        $Out = Protect-DiagnosticText $Conn $null
        $Out | Should -Not -Match ([regex]::Escape($Secret))
        $Out | Should -Match 'AccountKey=<redacted>'
        $Out | Should -Match 'EndpointSuffix=core\.windows\.net'
    }

    It "redacts a SharedAccessKey value while the SharedAccessKeyName key name survives" {
        $Secret = [guid]::NewGuid().ToString('N') + '='
        $Conn = "SharedAccessKeyName=RootManage;SharedAccessKey=$Secret"
        $Out = Protect-DiagnosticText $Conn $null
        $Out | Should -Not -Match ([regex]::Escape($Secret))
        $Out | Should -Match 'SharedAccessKey=<redacted>'
        $Out | Should -Match 'SharedAccessKeyName=RootManage'
    }

    It "redacts a Password value while the following Encrypt segment survives readable" {
        $Secret = [guid]::NewGuid().ToString('N')
        $Conn = "User ID=u;Password=$Secret;Encrypt=true"
        $Out = Protect-DiagnosticText $Conn $null
        $Out | Should -Not -Match ([regex]::Escape($Secret))
        $Out | Should -Match 'Password=<redacted>'
        $Out | Should -Match 'Encrypt=true'
    }

    It "redacts a client_secret value while client_id and scope survive readable" {
        $Secret = [guid]::NewGuid().ToString('N')
        $Conn = "client_id=id&client_secret=$Secret&scope=x"
        $Out = Protect-DiagnosticText $Conn $null
        $Out | Should -Not -Match ([regex]::Escape($Secret))
        $Out | Should -Match 'client_secret=<redacted>'
        $Out | Should -Match 'client_id=id'
        $Out | Should -Match 'scope=x'
    }
}
