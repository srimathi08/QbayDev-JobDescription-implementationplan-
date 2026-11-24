# Salesforce DX Project

Salesforce DX is a development approach that brings source-driven development, team collaboration, and continuous integration to the Salesforce Platform. Instead of working directly in an org through a web browser, you work with metadata as source files in a local DX project, track changes in version control, and deploy through automated processes.

This project template gets you started with the tools and structure you need to build Salesforce applications using source control, scratch orgs, and the Salesforce CLI.

## Prerequisites

Before you start, make sure you have:

- **Salesforce CLI** - Download from [developer.salesforce.com/tools/salesforcecli](https://developer.salesforce.com/tools/salesforcecli). See [Install Salesforce CLI](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm) for details.
- **VS Code with Salesforce Extension Pack** - See [Installation Instructions](https://developer.salesforce.com/docs/platform/sfvscode-extensions/guide/install.html) for details. Includes the Agentforce Vibes extension.
- **A development org** - Sign up for a free Developer Edition org [here](https://developer.salesforce.com/signup).
- **Dev Hub enabled** (optional, required to create scratch orgs) - You can enable Dev Hub in your development org under Setup > Dev Hub.  See [Provide Developers Access to Salesforce DX Tools](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_setup_dx_tools.htm).

## Project Structure

Your DX project follows this structure:

- **`force-app/main/default/`** - Your metadata source files live in this default package directory. You can configure additional package directories in the `sfdx-project.json` file.
- **`config/`** - Scratch org definitions and project settings
- **`scripts/`** - Automation scripts for common tasks
- **`sfdx-project.json`** - Project manifest that defines package directories, namespace, API version, and other project-level settings

See [Salesforce DX Project Configuration](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_ws_config.htm).

## Get Started

Ready to start developing? The [Get Started with Salesforce DX](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_get_started_dx.htm) guide walks you through your first project, from creating a scratch org to creating a simple Apex class or LWC to deploying your code to a sandbox.

## Common Salesforce CLI Commands

Here are common CLI commands that you'll use the most:

- `sf org login web`: Authorize an org
- `sf org open`: Open your org in a browser
- `sf org create scratch`: Create a scratch org
- `sf project deploy start`: Deploy metadata to your org
- `sf project retrieve start`: Retrieve metadata from your org
- `sf template generate <artifact>`: Scaffold new components, such as Apex classes and triggers, LWC components, Lightning apps, and more
- `sf apex <command>`: Run Apex tests, run anonymous Apex blocks, and view logs
- `sf data <command>`: Work with test data
- `sf alias <command>`: Manage org aliases
- `sf config <command>`: Configure CLI settings

## Use Agentforce Vibes to Build Lightning Apps

Transform your ideas into custom Lightning apps that extend CRM workflows directly in Lightning Experience. Through natural conversations with Agentforce Vibes, implement custom objects and fields, complex business logic, and dynamic UI components. See [Build a Lightning App Using Agentforce Vibes](https://developer.salesforce.com/docs/platform/einstein-for-devs/guide/lexapp-overview.html).

## Additional Resources

- [Agentforce Vibes Developer Guide](https://developer.salesforce.com/docs/platform/einstein-for-devs/guide/einstein-overview.html)
- [Salesforce CLI Installation Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/)
- [Salesforce CLI Plugin Development Guide](https://developer.salesforce.com/docs/platform/salesforce-cli-plugin/guide/conceptual-overview.html)
- [Salesforce VS Code Extensions Documentation](https://developer.salesforce.com/tools/vscode/)


## Backup of QbayDev sandbox taken on 2026-11-24 13:07 IST before upload-flow changes

- Org: QbayDev sandbox (https://innovation-dream-9744--qbaydev.sandbox.my.salesforce.com), CLI alias `QbayDevJobdes`
- Manifest: `manifest/full-backup.xml`, generated with `sf project generate manifest --from-org` (114 metadata types, unmanaged components only)
- Retrieve: `sf project retrieve start --manifest manifest/full-backup.xml --ignore-conflicts`. Read-only; nothing was deployed or changed in the org.
- Components retrieved: 10206; files under force-app: 10206

### Key metadata types

| Type | Count |
|---|---|
| ApexClass | 484 |
| ApexTrigger | 22 |
| LightningComponentBundle | 200 |
| AuraDefinitionBundle | 0 (none in org) |
| Flow | 19 |
| FlexiPage | 72 |
| CustomObject | 507 |
| CustomField | 5527 |
| RecordType | 19 |
| ValidationRule | 8 |
| Layout | 173 |
| GenAiPromptTemplate | 11 |
| CustomMetadata | 8 |
| PermissionSet | 10 |
| Profile | 42 |
| StaticResource | 412 |
| CustomTab | 42 |
| CustomApplication | 39 |
| DuplicateRule | 5 |
| MatchingRules | 4 |

### All retrieved types

| Type | Count |
|---|---|
| ActionableListDefinition | 2 |
| AnalyticsDashboard | 1 |
| AnalyticsWorkspace | 1 |
| ApexClass | 484 |
| ApexComponent | 8 |
| ApexEmailNotifications | 1 |
| ApexPage | 68 |
| ApexTrigger | 22 |
| ApplicationSubtypeDefinition | 1 |
| AppMenu | 2 |
| AssignmentRules | 2 |
| Audience | 6 |
| AuthProvider | 10 |
| AutoResponseRules | 2 |
| BusinessProcess | 3 |
| BusinessProcessTypeDefinition | 1 |
| CampaignInfluenceModel | 1 |
| CleanDataService | 3 |
| Community | 1 |
| CompactLayout | 6 |
| CustomApplication | 39 |
| CustomField | 5527 |
| CustomLabels | 1 |
| CustomMetadata | 8 |
| CustomObject | 507 |
| CustomObjectTranslation | 669 |
| CustomSite | 10 |
| CustomTab | 42 |
| Dashboard | 17 |
| DashboardFolder | 15 |
| DataConnectorIngestApi | 1 |
| DataSource | 18 |
| DataSourceObject | 44 |
| DataSourceTenant | 2 |
| DataStreamDefinition | 43 |
| DigitalExperience | 58 |
| DigitalExperienceBundle | 1 |
| DigitalExperienceConfig | 1 |
| DocumentFolder | 3 |
| DuplicateRule | 5 |
| EmailFolder | 1 |
| EmailServicesFunction | 2 |
| EmailTemplate | 176 |
| EntitlementProcess | 1 |
| EscalationRules | 1 |
| ExplainabilityActionDefinition | 1 |
| ExplainabilityActionVersion | 1 |
| ExternalDataConnector | 2 |
| FieldRestrictionRule | 6 |
| FieldSet | 2 |
| FieldSrcTrgtRelationship | 26 |
| FlexiPage | 72 |
| Flow | 19 |
| FlowDefinition | 19 |
| ForecastingSourceDefinition | 1 |
| ForecastingType | 13 |
| ForecastingTypeSource | 1 |
| GenAiPromptTemplate | 11 |
| Group | 1 |
| HomePageLayout | 1 |
| IframeWhiteListUrlSettings | 1 |
| InstalledPackage | 5 |
| InternalDataConnector | 2 |
| KeywordList | 6 |
| Layout | 173 |
| LightningComponentBundle | 200 |
| ListView | 94 |
| ManagedContentType | 3 |
| ManagedTopics | 6 |
| MatchingRules | 4 |
| MilestoneType | 3 |
| MktDataConnection | 4 |
| MktDataTranObject | 44 |
| ModerationRule | 30 |
| NavigationMenu | 6 |
| Network | 6 |
| NetworkBranding | 12 |
| NotificationTypeConfig | 1 |
| ObjectSourceTargetMap | 102 |
| PathAssistant | 2 |
| PermissionSet | 10 |
| PermissionSetGroup | 22 |
| PolicyRuleDefinition | 1 |
| PolicyRuleDefinitionSet | 1 |
| Profile | 42 |
| ProfilePasswordPolicy | 14 |
| ProfileSessionSetting | 14 |
| QuickAction | 78 |
| RecordType | 19 |
| RemoteSiteSetting | 1 |
| Report | 206 |
| ReportFolder | 26 |
| ReportType | 35 |
| Role | 6 |
| Settings | 205 |
| SharingRules | 213 |
| SiteDotCom | 10 |
| StandardValueSet | 52 |
| StandardValueSetTranslation | 32 |
| StaticResource | 412 |
| StreamingAppDataConnector | 1 |
| TopicsForObjects | 69 |
| UserCriteria | 18 |
| ValidationRule | 8 |
| WebLink | 12 |
| Workflow | 2 |

### Items that could not be retrieved (284)

These are standard or platform-generated entries in the org-generated manifest that the Metadata API cannot return. None of them are custom code or configuration:

- CustomField (18): historical-trending fields on `ForecastingItem__hd` / `Opportunity__hd`
- ListView (137): standard-object list views for features that aren't enabled
- ExternalDataTranObject (14): Agentforce session/log Data Cloud objects
- WorkflowFlowAutomation (19): duplicate entries for flows; all 19 flows were retrieved as `Flow`
- ExperienceBundle (1): A_iBRAVE_HRMS1 (the site is retrieved as DigitalExperienceBundle/SiteDotCom)
- MktDataConnection (2): UploadedFiles, TenantBillingUsageEvent
- Other (93): entity types not available in this org, or non-customizable standard objects

