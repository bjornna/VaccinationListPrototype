[CmdletBinding()]
Param()

function Get-PlainText([System.Security.SecureString]$SecureString)
{
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString);

    try
    {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) | Write-Output
    }
    finally
    {
        [Runtime.InteropServices.Marshal]::FreeBSTR($bstr);
    }
}

$vaultBaseUrlNO = 'https://hashivault.dips.local'
$vaultBaseUrlSL = 'https://hashivault.creativesoftware.com'

$domainName = ($Env:UserDnsDomain).ToLower()
if ($domainName -eq 'creativesoftware.com' -or $domainName -eq 'dipscloud.com')
{
    $vaultBaseUrl = $vaultBaseUrlSL
}
else
{
    $vaultBaseUrl = $vaultBaseUrlNO
}

$userName = Read-Host 'Vault user name (AD)'
$password = Read-Host 'Vault password' -AsSecureString

$logonUrl = "$($vaultBaseUrl)/v1/auth/ldap/login/$($userName)"
$body = "{`"password`": `"$(Get-PlainText $password)`"}"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$responseJson = Invoke-WebRequest -Uri $logonUrl -Method 'POST' -Body $body -UseBasicParsing

if ([string]::IsNullOrWhiteSpace($responseJson))
{
    Write-Error 'Unable to log in with the specified credentials.'
    exit 1
}

$response = ConvertFrom-Json $responseJson

Write-Host 'Successfully logged in!' -ForegroundColor 'Green'
Write-Host "Lease duration: $($response.auth.lease_duration)s" -ForegroundColor 'Green'
Write-Host 'Token policies:' -ForegroundColor 'Green'
foreach ($policy in $response.auth.token_policies)
{
    Write-Host " - $policy" -ForegroundColor 'Green'
}

$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'

$tokenFilePath = 'C:\temp\DIPSBuildsystem\token.json'
$tokenInfo = @{
    'VaultToken' = $response.auth.client_token
    'VaultTokenLeaseDuration' = $response.auth.lease_duration
    'VaultTokenIssueTimestamp' = $now
}
$tokenInfoJson = ConvertTo-Json $tokenInfo

Set-Content -Path $tokenFilePath -Value $tokenInfoJson

[Environment]::SetEnvironmentVariable('VAULT_TOKEN', $response.auth.client_token)
[Environment]::SetEnvironmentVariable('VAULT_TOKEN_LEASE_DURATION', $response.auth.lease_duration)
[Environment]::SetEnvironmentVariable('VAULT_TOKEN_ISSUE_TIMESTAMP', $now)