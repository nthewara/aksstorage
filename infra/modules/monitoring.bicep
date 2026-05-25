param location string
param nameBase string

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${nameBase}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

output workspaceId string = law.id
output workspaceName string = law.name
