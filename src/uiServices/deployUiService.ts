import { utils } from "mocha";
import * as vscode from "vscode";
import { commands, ExtensionContext, QuickPickOptions, window, workspace, WorkspaceFolder } from "vscode";
import { Constants } from "../constants";
import Controller from "../controller";
import { DeployService } from "../deployService/services/deployService";
import { UiService } from "../extensionController";
import { GoCurrentPsService } from "../goCurrentService/services/goCurrentPsService";
import { UiHelpers } from "../helpers/uiHelpers";
import { QuickPickItemPayload } from "../interfaces/quickPickItemPayload";
import { Deployment } from "../models/deployment";
import { PackageGroup } from "../models/projectFile";
import { UpdateAvailable } from "../models/updateAvailable";
import Resources from "../resources";
import { WorkspaceServiceProvider, WorkspaceContainerEvent } from "../workspaceService/services/workspaceServiceProvider";
import * as util from 'util'
import { PackageInfo } from "../interfaces/packageInfo";
import { BaseUiService } from "./baseUiService";
import { WorkspaceHelpers } from "../helpers/workspaceHelpers";
import { Logger } from "../interfaces/logger";
import { DeploymentPayload } from "../models/deploymentPayload";
import { DeploymentResult } from "../models/deploymentResult";

export class DeployUiService extends UiService
{
    private _wsDeployServices: WorkspaceServiceProvider<DeployService>;
    private _goCurrentPsService: GoCurrentPsService;

    private _disposable: vscode.Disposable;

    constructor(
        context: ExtensionContext, 
        logger: Logger,
        wsDeployServices: WorkspaceServiceProvider<DeployService>,
        goCurrentPsService: GoCurrentPsService
    )
    {
        super(context, logger);
        this._wsDeployServices = wsDeployServices;
        this._goCurrentPsService = goCurrentPsService;
    }

    async activate(): Promise<void>
    {
        this.registerCommand("ls-update-service.deploy", this.install);
        this.registerCommand("ls-update-service.manage", this.manage);
        this.registerCommand("ls-update-service.checkForUpdates", this.checkForUpdates);
        this.registerCommand("ls-update-service.update", this.update);
        this.registerCommand("ls-update-service.remove", this.remove);
        this.registerCommand("ls-update-service.addInstanceToWorkspace", this.addInstanceToWorkspace);
        this.registerCommand("ls-update-service.viewResolvedProjectFile", this.viewResolvedProjectFile);

        let subscriptions: vscode.Disposable[] = [];
        this._wsDeployServices.onDidChangeWorkspaceFolders(this.onWorkspaceChanges, this, subscriptions);
        this._disposable = vscode.Disposable.from(...subscriptions);
    }

    async dispose()
    {
        this._disposable?.dispose();
    }

    private onWorkspaceChanges(e: WorkspaceContainerEvent<DeployService>)
    {
        for (let workspaceFolder of e.workspaceChanges.added)
        {
            let deployService = e.workspaceContainer.getService(workspaceFolder);
            let subscriptions: vscode.Disposable[] = [];
            deployService.onDidInstanceRemoved(e => {
                this.checkForUpdatesSilent();
            }, this, subscriptions);
            deployService.onDidProjectFileChange(e => {
                this.checkForUpdatesSilent();
                this.checkAndUpdateIfActive();
            }, this, subscriptions);
            e.pushSubscription(workspaceFolder, vscode.Disposable.from(...subscriptions));
        }

        this.checkAndUpdateIfActive();
        // Make sure we only check for updates after we know that GoC is installed.
        if (!this._goCurrentPsService.isInitialized)
        {
            this._goCurrentPsService.onDidInitilize(e => {
                this.checkForUpdatesSilent();
            }, this);
        }
        else
        {
            if (e.workspaceChanges.added.length > 0)
                UiHelpers.schedule(5000, () => {this.checkForUpdatesSilent()});
        }
    }

    private async checkAndUpdateIfActive()
    {
        let anyActive = await this._wsDeployServices.anyActive();

        commands.executeCommand("setContext", Constants.goCurrentDeployActive, anyActive);
    }

    private async install()
    {
        let activeWorkspaces = await this._wsDeployServices.getWorkspaces({
            serviceFilter: async service => await service.hasPackageGroups(),
            active: true
        })

        if (activeWorkspaces.length === 0)
        {
            window.showInformationMessage("Nothing to install.");
            return;
        }

        let workspaceFolder = await UiHelpers.showWorkspaceFolderPick(activeWorkspaces);
        if (!workspaceFolder)
            return;

        await this.showDeployWithService(this._wsDeployServices.getService(workspaceFolder), workspaceFolder);
    }

    private async manage()
    {
        let workspaces = await this._wsDeployServices.getWorkspaces({
            active: true,
            serviceFilter: service => service.hasPackagesInstalled()}
        );

        if (!workspaces || workspaces.length === 0)
        {
            window.showInformationMessage("No installs to manage.")
            return;
        }

        let deploymentPayload = await this.getAllDeployments(workspaces, "Select a package group to manage");
        
        if (!deploymentPayload)
            return;

        let choices = [Constants.buttonAssignedGroup, Constants.buttonCheckUpdates, Constants.buttonRemove]
        
        let picked = await window.showQuickPick(choices, {
            placeHolder: util.format(Resources.managePackages)
        });
        if (!picked)
        {
            return;
        }

        if (picked === Constants.buttonCheckUpdates)
            return await this.checkForUpdates(deploymentPayload.deployment, deploymentPayload.deployService);
        
        else if (picked === Constants.buttonRemove)
            return await this.removedPicked(deploymentPayload);
        
        if (await this.updatePicked(deploymentPayload))
            await this.checkForUpdatesSilentDeployment(deploymentPayload.deployment, deploymentPayload.deployService)
        
    }

    private async removedPicked(deploymentPayload: DeploymentPayload)
    {
        let name = deploymentPayload.deployment.name;
        if (!name)
            name = deploymentPayload.deployment.instanceName;
        else if (deploymentPayload.deployment.instanceName)
            name += ` (${deploymentPayload.deployment.instanceName})`;

        let choicesRemove = [Constants.buttonYes, Constants.buttonNo]
        
        let pickedRemoved = await window.showQuickPick(choicesRemove, {
            placeHolder: util.format(Resources.areYourSureAboutRemove, name)
        });

        if (pickedRemoved === Constants.buttonNo)
            return;

        let removedName = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: "Removing package(s) ..."
        }, async (progress, token) => {
            return await deploymentPayload.deployService.removeDeployment(deploymentPayload.deployment.guid);
        });
        window.showInformationMessage(`Package(s) "${removedName}" removed.`);
    }

    private async updatePicked(deploymentPayload: DeploymentPayload): Promise<boolean>
    {
        if (!this._wsDeployServices.getService(deploymentPayload.workspaceFolder).hasPackageGroups())
        {
            window.showInformationMessage("There is no package groups on this workspace.");
            return false;
        }

       return await this.showUpdateWithService(this._wsDeployServices.getService(deploymentPayload.workspaceFolder), deploymentPayload);
    }

    private async showUpdateWithService(deployService: DeployService, deploymentPayload: DeploymentPayload): Promise<boolean>
    {
        let packageGroups = await deployService.getPackageGroupsResolved();

        let picks: QuickPickItemPayload<PackageGroup>[] = [];

        for (let entry of packageGroups)
        {
            if (await deployService.canInstall(entry.id))
            {
                picks.push({
                    "label": entry.name, 
                    "description": entry.description, 
                    "detail": entry.packages.filter(p => !p.onlyRestrictVersion).map(p => `${p.id}`).join(', '),
                    "payload": entry
                });
            }
        }

        var options: vscode.QuickPickOptions = {};
        options.placeHolder = "Select a packages to update"
        let selectedSet = await window.showQuickPick(picks, options);
        if (!selectedSet)
            return false;

        let targets = await deployService.getTargets(selectedSet.payload.id, true);

        let selectedTarget = await UiHelpers.showTargetPicks(targets)

        if (!selectedTarget)
            return;

        deploymentPayload.deployment.id = selectedSet.payload.id;
        deploymentPayload.deployment.target = selectedTarget;

        let result = await deployService.updatePackage(deploymentPayload.deployment);
        if (!result)
        {
            window.showErrorMessage("There was an error finding the chosen deployment.");
            return false;
        }
        window.showInformationMessage("The install was assigned to the group.")
        return true;
    }

    private async showDeployWithService(deployService: DeployService, workspaceFolder: WorkspaceFolder)
    {
        let packageGroups = await deployService.getPackageGroupsResolved();

        let picks: QuickPickItemPayload<PackageGroup>[] = [];

        for (let entry of packageGroups)
        {
            if (await deployService.canInstall(entry.id))
            {
                picks.push({
                    "label": entry.name, 
                    "description": entry.description, 
                    "detail": entry.packages.filter(p => !p.onlyRestrictVersion).map(p => `${p.id}`).join(', '),
                    "payload": entry
                });
            }
        }

        var options: vscode.QuickPickOptions = {};
        options.placeHolder = "Select a packages to install"
        let selectedSet = await window.showQuickPick(picks, options);
        if (!selectedSet)
            return;

        let targets = await deployService.getTargets(selectedSet.payload.id);

        let selectedTarget = await UiHelpers.showTargetPicks(targets)

        if (!selectedTarget)
            return;

        let instanceName = "";
        if (await deployService.isInstance(selectedSet.payload.id))
        {
            instanceName = selectedSet.payload.instanceName;
            if (!instanceName)
            {
                let suggestion = selectedSet.payload.instanceNameSuggestion
                if (!suggestion)
                    suggestion = workspaceFolder.name
                instanceName = await UiHelpers.getOrShowInstanceNamePick(suggestion, this._goCurrentPsService);
                if (!instanceName)
                    return;
            }
            else
            {
                if (this._goCurrentPsService.testInstanceExists(instanceName))
                {
                    window.showErrorMessage(`Instance with the name "${instanceName}" is already installed.`)
                    return;
                }
            }
        }

        let deploymentResult = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: Resources.installationStartedInANewWindow
        }, async (progress, token) => {
            return await deployService.deployPackageGroup(
                selectedSet.payload,
                instanceName,
                selectedTarget,
                undefined
            );
        });
        
        if (deploymentResult.lastUpdated.length > 0)
            window.showInformationMessage(`Package group "${deploymentResult.deployment.name}" installed: ` + deploymentResult.lastUpdated.map(p => `${p.id} v${p.version}`).join(', '));
    }

    private async checkForUpdates(deployment?: Deployment, deployService?: DeployService)
    {
        let anyUpdates = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: Resources.checkingForUpdates
        }, async (progress, token) => {

            let update = await BaseUiService.checkForGocWorkspaceUpdates(this._goCurrentPsService, this.context);
            update = update || await BaseUiService.checkForUpdates(["go-current-server", "go-current-client", "ls-package-tools"], this._goCurrentPsService);
            if (!deployment || !deployService)
                return (await this.checkForUpdatesSilent()) || update;
            return (await this.checkForUpdatesSilentDeployment(deployment, deployService)) || update;
        });

        if (!anyUpdates)
        {
            window.showInformationMessage("No updates available.");
        }
    }

    private async checkForUpdatesSilent(): Promise<boolean>
    {
        let buttons: string[] = [Constants.buttonUpdate, Constants.buttonLater];
        let anyUpdates = false;
        for (let deployService of (await this._wsDeployServices.getServices({active: true})))
        {
            deployService.UpdatesAvailable = new Array<UpdateAvailable>();
            let updates = await deployService.checkForUpdates();
            
            for (let update of updates)
            {
                anyUpdates = await this.checkUpdatesSilentFinal(update, deployService, anyUpdates);
            }
        }

        return anyUpdates;
    }

    private async checkForUpdatesSilentDeployment(deployment: Deployment, deployService: DeployService): Promise<boolean>
    {
        let anyUpdates = false;
        
        deployService.UpdatesAvailable = new Array<UpdateAvailable>();
        let update = await deployService.checkForUpdatesDeployment(deployment);
        
        if (update)
        {
            anyUpdates = await this.checkUpdatesSilentFinal(update, deployService, anyUpdates);
        }
        return anyUpdates;
    }

    private async checkUpdatesSilentFinal(update: UpdateAvailable, deployService: DeployService, anyUpdates: boolean): Promise<boolean>
    {
        let buttons: string[] = [Constants.buttonUpdate, Constants.buttonLater];
        let message : string;
        if (update.error)
        {
            message = `Error occured for "${update.instanceName}"`;
            if (update.instanceName)
                message += ` (${update.instanceName})`;
            message += ` ${update.error}`;
            window.showErrorMessage(message);
        }
        else
        {
            anyUpdates = true;
            message = `Updates available for "${update.packageGroupName}"`;

            if (update.instanceName)
                message += ` (${update.instanceName})`;

            window.showInformationMessage(message, ...buttons,).then(result => 
            {
                if (result === Constants.buttonUpdate)
                {
                    this.installUpdate(deployService, update);
                }
                else
                {
                    if (!deployService.UpdatesAvailable.find(i => i.packageGroupId === update.packageGroupId && i.instanceName === update.instanceName))
                    {
                        deployService.UpdatesAvailable.push(update);
                        commands.executeCommand("setContext", Constants.goCurrentDeployUpdatesAvailable, true);
                    }
                }
            });
        }
        return anyUpdates;
    }

    private async installUpdate(deployService: DeployService, update: UpdateAvailable) : Promise<boolean>
    {
        let deploymentResult = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: Resources.installationStartedInANewWindow
        }, async (progress, token) => {
            return await deployService.installUpdate(update.packageGroupId, update.instanceName, update.guid);
        });
        
        if (deploymentResult.lastUpdated.length > 0)
        {
            window.showInformationMessage(`Package group "${deploymentResult.deployment.name}" updated: ` + deploymentResult.lastUpdated.map(p => `${p.id} v${p.version}`).join(', '));
            return true;
        }
        return false;
    }

    private async update()
    {
        let picks = new Array<QuickPickItemPayload<DeployService, UpdateAvailable>>();

        for (let service of await this._wsDeployServices.getServices({active: true}))
        {
            for (let entry of service.UpdatesAvailable)
            {
                let instanceName = "";
                if (entry.instanceName)
                    instanceName = "("+ entry.instanceName + ")";
                picks.push({
                    "label": entry.packageGroupName, 
                    "description": instanceName,
                    "detail": entry.packages.map(p => p.id + " v" + p.version).join(', '),
                    "payload": service,
                    "payload2": entry,
                });
            }
        }
        let result = await window.showQuickPick<QuickPickItemPayload<DeployService, UpdateAvailable>>(picks, {"placeHolder": "Select a package group to update"});
        
        if (!result)
            return;

        let deployService = result.payload;

        if (!deployService)
            return

        let update = result.payload2;
        let success = await this.installUpdate(deployService, update)
        if (success)
        {
            let idx = deployService.UpdatesAvailable.findIndex(u => u.packageGroupId === result.payload2.packageGroupId && u.instanceName === result.payload2.instanceName);
            if (idx > -1)
                deployService.UpdatesAvailable.splice(idx, 1);
        }
        commands.executeCommand("setContext", Constants.goCurrentDeployUpdatesAvailable, await this.anyUpdatesPending());
    }

    private async anyUpdatesPending() : Promise<boolean>
    {
        for (let service of await this._wsDeployServices.getServices({active: true}))
        {
            if (service.UpdatesAvailable && service.UpdatesAvailable.length > 0)
                return true;
        }
        
        return false;
    }

    private async remove()
    {
        let workspaces = await this._wsDeployServices.getWorkspaces({
            active: true,
            serviceFilter: service => service.hasPackagesInstalled()}
        );

        if (!workspaces || workspaces.length === 0)
        {
            window.showInformationMessage("Nothing to remove.")
            return;
        }

        let workspaceFolder = await UiHelpers.showWorkspaceFolderPick(workspaces);

        if (!workspaceFolder)
            return;

        let deployService = this._wsDeployServices.getService(workspaceFolder);

        let deploymentPayload = await this.getDeployment(deployService, workspaceFolder, "Select a package group to remove");

        if (!deploymentPayload)
            return;

        let choices = [Constants.buttonYes, Constants.buttonNo]

        let name = deploymentPayload.deployment.name;
        if (!name)
            name = deploymentPayload.deployment.instanceName;
        else if (deploymentPayload.deployment.instanceName)
            name += ` (${deploymentPayload.deployment.instanceName})`;
        
        let picked = await window.showQuickPick(choices, {
            placeHolder: util.format(Resources.areYourSureAboutRemove, name)
        });

        if (picked === Constants.buttonNo)
            return;

        let removedName = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: "Removing package(s) ..."
        }, async (progress, token) => {
            return await deployService.removeDeployment(deploymentPayload.deployment.guid);
        });
        window.showInformationMessage(`Package(s) "${removedName}" removed.`);
    }

    private async showDeploymentsPicksList(deploymentList: DeploymentPayload[], placeholder: string = "Selected a group") : Promise<DeploymentPayload>
    {
        let picks: QuickPickItemPayload<DeploymentPayload>[] = [];

        for (let entry of deploymentList)
        {
            let instance = "";
            if (entry.deployment.instanceName && entry.deployment.instanceName !== entry.deployment.name)
                instance = " (" + entry.deployment.instanceName + ")"
                
            picks.push({
                "label": entry.deployment.name,
                "description": instance,
                "detail": entry.deployment.packages.map(p => `${p.id} v${p.version}`).join('\n'),
                "payload": entry
            });
        }
        var options: QuickPickOptions = {};
        options.placeHolder = placeholder
        let selected = await window.showQuickPick(picks, options);
        if (!selected)
            return;
        return selected.payload;
    }

    private async getAllDeployments(workspaceFolders: WorkspaceFolder[], placeholder: string = "Selected a group")  : Promise<DeploymentPayload>
    {
        let deploymentsPayload: DeploymentPayload[] = [];
        if (!workspaceFolders)
            return;
        for (let workspaceFolder of workspaceFolders)
        {
            let deployService = this._wsDeployServices.getService(workspaceFolder);
            let deploymentAux = await deployService.getDeployments();
            let deploymentPayloadAux: DeploymentPayload[] = this.addDeploymentToDeploymentPayload(deploymentAux, deployService, workspaceFolder);
            deploymentsPayload = deploymentsPayload.concat(deploymentPayloadAux);
        }
        return this.showDeploymentsPicksList(deploymentsPayload,placeholder);;
    }

    private async getDeployment(deployService: DeployService,workspaceFolder: WorkspaceFolder, placeholder: string = "Selected a group") : Promise<DeploymentPayload>
    {
        let deployments = await deployService.getDeployments();
        let deploymentsPayload = this.addDeploymentToDeploymentPayload(deployments, deployService, workspaceFolder)
        return this.showDeploymentsPicksList(deploymentsPayload,placeholder);
    }

    private addDeploymentToDeploymentPayload(deployments: Deployment[], deployService: DeployService, workspaceFolder: WorkspaceFolder) : DeploymentPayload[]
    {
        let deploymentsPayloadList: DeploymentPayload[] = []
        for (let deployment of deployments)
        {
            let deployPayload = new DeploymentPayload();
            deployPayload.deployment = deployment;
            deployPayload.deployService = deployService;
            deployPayload.workspaceFolder = workspaceFolder;
            deploymentsPayloadList.push(deployPayload);
        }
        return deploymentsPayloadList;
    }

    private async addInstanceToWorkspace()
    {
        let workspaceFolder = await UiHelpers.showWorkspaceFolderPick(await this._wsDeployServices.getWorkspaces({active: true}));

        if (!workspaceFolder)
            return;

        let deployService = this._wsDeployServices.getService(workspaceFolder);
        let existingInstances = await deployService.getDeployedInstances()

        let packages = await this.showInstancePicks(existingInstances);

        if (!packages)
            return;

        deployService.addPackagesAsDeployed(packages);
        
    }

    async showInstancePicks(exludeInstances: Array<string> = [], placeholder: string = "Select an instance") : Promise<PackageInfo[]>
    {
        let instances = await this._goCurrentPsService.getInstances();

        let picks: QuickPickItemPayload<PackageInfo[]>[] = [];

        for (let entry of instances)
        {
            let instanceName = entry[0].InstanceName;

            if (exludeInstances.includes(instanceName))
                continue;

            let description = entry.filter(p => p.Selected).map(p => `${p.Id}`).join(', ');
            picks.push({
                "label": instanceName,
                "description": description,
                "payload": entry
            });
        }
        var options: QuickPickOptions = {};
        options.placeHolder = placeholder
        let selected = await window.showQuickPick(picks, options);
        if (!selected)
            return;
        return selected.payload;
    }

    async viewResolvedProjectFile(item): Promise<void>
    {
        if (!item || !item.fsPath)
            return;
            
        let filePath = item.fsPath;

        let workspaceFolder = WorkspaceHelpers.getWorkspaceForPath(filePath);

        if (!workspaceFolder)
            return;

        let deployService = this._wsDeployServices.getService(workspaceFolder);       

        let targets = await deployService.getTargets(undefined, false);

        let selectedTarget = await UiHelpers.showTargetPicks(targets)

        if (!selectedTarget)
            return;

        let projectFileResolved: any = await deployService.getResolvedProjectFile(selectedTarget);
        projectFileResolved.DevPackageGroups = await deployService.getResolvedPackageGroups(selectedTarget);

        const panel = vscode.window.createWebviewPanel(
            'projectFile',
            'Resolved Project File',
            vscode.ViewColumn.One,
            {}
        );
        
        panel.webview.html = '<pre>' + JSON.stringify(projectFileResolved, null, 4) +'</pre>';
    }   
}