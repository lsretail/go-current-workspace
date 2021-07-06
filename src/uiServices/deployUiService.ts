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
import { BaseUiService } from "./BaseUiService";
import { WorkspaceHelpers } from "../helpers/workspaceHelpers";
import { Logger } from "../interfaces/logger";

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
                this.checkForUpdatesSilent();
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

    private async checkForUpdates()
    {
        let anyUpdates = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: Resources.checkingForUpdates
        }, async (progress, token) => {

            let update = await BaseUiService.checkForGocWorkspaceUpdates(this._goCurrentPsService, this.context);
            update = update || await BaseUiService.checkForUpdates(["go-current-server", "go-current-client", "ls-package-tools"], this._goCurrentPsService);

            return (await this.checkForUpdatesSilent()) || update;
        });

        if (!anyUpdates)
        {
            window.showInformationMessage("No updates available.");
        }
    }

    private async checkForUpdatesSilent(): Promise<boolean>
    {
        let buttons: string[] = [Constants.buttonUpdate, Constants.buttonLater];
        //commands.executeCommand("setContext", Constants.goCurrentDeployUpdatesAvailable, false);
        let anyUpdates = false;
        for (let deployService of (await this._wsDeployServices.getServices({active: true})))
        {
            deployService.UpdatesAvailable = new Array<UpdateAvailable>();
            let updates = await deployService.checkForUpdates();
            
            for (let update of updates)
            {
                let message : string;
                if (update.error)
                {
                    message = `There is an error on "${update.instanceName} ${update.packageGroupName} ${update.error}"`;
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
            }
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

        let deployment = await this.showDeploymentsPicks(deployService, "Select a package group to remove");

        if (!deployment)
            return;

        let choices = [Constants.buttonYes, Constants.buttonNo]

        let name = deployment.name;
        if (!name)
            name = deployment.instanceName;
        else if (deployment.instanceName)
            name += ` (${deployment.instanceName})`;
        
        let picked = await window.showQuickPick(choices, {
            placeHolder: util.format(Resources.areYourSureAboutRemove, name)
        });

        if (picked === Constants.buttonNo)
            return;

        let removedName = await window.withProgress({
            location: vscode.ProgressLocation.Notification,
            title: "Removing package(s) ..."
        }, async (progress, token) => {
            return await deployService.removeDeployment(deployment.guid);
        });
        window.showInformationMessage(`Package(s) "${removedName}" removed.`);
    }

    private async showDeploymentsPicks(deployService: DeployService, placeholder: string = "Selected a group") : Promise<Deployment>
    {
        let deployments = await deployService.getDeployments();
        let picks: QuickPickItemPayload<Deployment>[] = [];

        for (let entry of deployments)
        {
            let instance = "";
            if (entry.instanceName && entry.instanceName !== entry.name)
                instance = " (" + entry.instanceName + ")"
                
            picks.push({
                "label": entry.name,
                "description": instance,
                "detail": entry.packages.map(p => `${p.id} v${p.version}`).join('\n'),
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
            'Resolved Go Current Project File',
            vscode.ViewColumn.One,
            {}
        );
        
        panel.webview.html = '<pre>' + JSON.stringify(projectFileResolved, null, 4) + '<br>' + JSON.stringify(projectFileResolved, null, 4) +'</pre>';
    }   
}