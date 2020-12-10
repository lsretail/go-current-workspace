
import {PowerShell} from '../../PowerShell'
import {PackageInfo} from '../../interfaces/packageInfo';
import { Server, Package } from '../../models/projectFile';
import { GoCurrentVersion } from '../../interfaces/goCurrentVersion';

export class DeployPsService
{
    private _modulePath: string;

    private _powerShell: PowerShell;
    private _powerShellLongRunning: PowerShell;
    private _isAdmin: boolean;

    constructor(powerShell: PowerShell, modulePath: string)
    {
        this._powerShell = powerShell;
        this._powerShell.addModuleFromPath(modulePath);
        this._powerShell.setPreCommand("trap{if (Invoke-ErrorHandler $_) { continue };}");
        this._modulePath = modulePath;
    }

    public async isAdmin(): Promise<boolean>
    {
        if (!this._isAdmin)
            this._isAdmin = await this._powerShell.executeCommandSafe("Test-AdminAsJson", true);
        return this._isAdmin;
    }

    private async executeAsAdmin(commandName: string, parseJson: boolean, ...args: any[]) : Promise<any>
    {
        if (await this.isAdmin())
        {
            return this._powerShell.executeCommandSafe(commandName, parseJson, ...args);
        }
        else
        {
            return this._powerShell.executeCommandSafe(commandName + "Admin", parseJson, ...args);
        }
    }

    public getTestString(): Promise<string>
    {
        let param = {
            'Value': 'input parameter'
        }
        return this._powerShell.executeCommandSafe("Get-TestString", false, param);
    }

    public async installPackageGroup(
        projectFilePath: string,
        packageGroupId: string,
        instanceName: string,
        target: string,
        branchName: string,
        servers: Server[]
    ) : Promise<PackageInfo[]>
    {
        let param = {
            'ProjectFilePath': `'${projectFilePath}'`,
        }

        if (packageGroupId)
            param['packageGroupId'] = `'${packageGroupId}'`;

        if (instanceName)
            param['InstanceName'] = `'${instanceName}'`;

        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        let powerShell = this._powerShell.getNewPowerShell();
        try
        {
            let result = await powerShell.executeCommandSafe("Install-PackageGroup", true, param);
            return result;
        }
        finally
        {
            powerShell.dispose();
        }
    }

    public getAvailableUpdates(
        projectFilePath: string, 
        packageGroupId: string, 
        instanceName: string,
        branchName: string,
        target: string,
        servers: Server[]
    )
    {
        let param = {
            'ProjectFilePath': `'${projectFilePath}'`,
        }

        if (packageGroupId)
            param['PackageGroupId'] = `'${packageGroupId}'`;

        if (instanceName)
            param['InstanceName'] = `'${instanceName}'`;
        
        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;
        
        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        return this._powerShell.executeCommandSafe("Get-AvailableUpdates", true, param);
    }

    public removeDeployment(workspaceDataPath: string, deploymentGuid: string) : Promise<any>
    {
        let param = {
            'WorkspaceDataPath': `'${workspaceDataPath}'`,
            'DeploymentGuid': `'${deploymentGuid}'`,
        }
        return this.executeAsAdmin("Remove-Deployment", true, param);
    }

    public testIsInstance(
        projectFilePath: string,
        packageGroupId: string,
        servers: Server[],
        target?: string,
        branchName?: string,
    ) : Promise<any>
    {
        let param = {
            'ProjectFilePath': `'${projectFilePath}'`,
            'packageGroupId': `'${packageGroupId}'`
        };

        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;
        
        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;
        
        return this._powerShell.executeCommandSafe("Test-IsInstance", true, param);
    }

    public testCanInstall(projectFilePath: string, packageGroupId: string): Promise<boolean>
    {
        return this._powerShell.executeCommandSafe("Test-CanInstall", true, {"ProjectFilePath": projectFilePath, "packageGroupId": packageGroupId})
    }

    public getDeployedPackages(workspaceDataPath: string, deploymentGuid: string) : Promise<PackageInfo[]>
    {
         let param = {
            'WorkspaceDataPath': `'${workspaceDataPath}'`,
            'DeploymentGuid': `'${deploymentGuid}'`,
        }
        return this._powerShell.executeCommandSafe("Get-DeployedPackages", true, param);
    }

    public getTargets(projectFilePath: string, id?: string, useDevTarget?: boolean): Promise<string[]>
    {
        let param = {
            projectFilePath: `'${projectFilePath}'`,
            useDevTarget: false
        }

        if (id)
            param['id'] = `'${id}'`;

        if (useDevTarget !== undefined)
            param['useDevTarget'] = useDevTarget;

        return this._powerShell.executeCommandSafe("Get-Targets", true, param);
    }

    public getResolvedProjectFile(projectFilePath: string, target: string, branchName: string): Promise<object>
    {
        let param = {
            projectFilePath: `'${projectFilePath}'`,
            target: `'${target}'`,
            branchName: `'${branchName}'`
        }
        return this._powerShell.executeCommandSafe("Get-ResolvedProjectFile", true, param);
    }

    public getPackageGroup(projectFilePath: string, id: string, target: string, branchName: string): Promise<object>
    {
        let param = {
            projectFilePath: `'${projectFilePath}'`,
            packageGroupId:  `'${id}'`,
            target: `'${target}'`,
            branchName: `'${branchName}'`
        }
        return this._powerShell.executeCommandSafe("Get-ResolvedPackageGroup", true, param);
    }
}