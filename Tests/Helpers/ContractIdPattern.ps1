# The masked resource id shape that every inventory and metric id must take
# under -Obfuscate:
#   /subscriptions/<sub token>/resourcegroups/<rg token>/providers/<namespace>/<type>/<name token>[/<type>/<name token>...]
# Every subscription, resource group and name segment is a prod_/nonprod_
# token (a name token may carry a databricks_/aks_/vmss_ hint, a group token
# an mc_ hint); provider and type segments stay as written. A flat token or a
# real name left in any segment does not match.
function Get-RdaContractIdPattern
{
    $Guid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $P = '(?:prod|nonprod)_'
    $Names = '(?:/[a-z][a-z0-9.]*/' + $P + '(?:databricks_|aks_|vmss_)?' + $Guid + ')+'
    $Providers = '/providers/[a-z][a-z0-9.]*' + $Names
    return ('(?i)^/subscriptions/' + $P + $Guid + '/resourcegroups/' + $P + '(?:mc_)?' + $Guid + $Providers + '$')
}
