import path = require('path');
import { off } from 'process';
import { pathToFileURL } from 'url';
import * as vscode from 'vscode'
import { fsHelpers } from '../../fsHelpers';

export class AlExtensionService
{
    private _extension: vscode.Extension<any>;
    private _languageClient: any = null;

    constructor()
    {
        let possibleExtension = ['microsoft.al', 'ms-dynamics-smb.al']
        for (let ext of possibleExtension)
        {
            let extension = vscode.extensions.getExtension(ext);
            if (extension)
                this._extension = extension;
        }
    }

    public get isInstalled(): boolean
    {
        return !!this._extension;
    }

    public get isActive(): boolean
    {
        if (this._extension)
            return this._extension.isActive;
        return false;
    }

    public get compilerPath(): string
    {
        if (!this._extension)
            return undefined;

        let compilerPath = path.join(this._extension.extensionPath, 'bin', 'win32', 'alc.exe')
        if (fsHelpers.existsSync(compilerPath))
            return compilerPath
        return path.join(this._extension.extensionPath, 'bin', 'alc.exe')
    }

    public async start(): Promise<any>
    {
        if (!this.isActive)
            return;

        return this.languageServerClient.start();
    }

    public async stop(): Promise<any>
    {
        if (!this.isActive)
            return;

        return this.languageServerClient.stop();
    }

    private get languageServerClient(): any
    {
        if (!this.isActive)
            return undefined;

        if (!this._languageClient)
        {
            for (let idx in this._extension.exports.services)
            {
                if (this._extension.exports.services[idx].constructor.name === 'EditorService')
                {
                    this._languageClient = this._extension.exports.services[idx].languageServerClient;
                    break;
                }
            }
        }
        return this._languageClient;
    }

    getConfig(workspaceFolder: vscode.WorkspaceFolder): AlExtensionConfig
    {
        let config = vscode.workspace.getConfiguration('al', workspaceFolder);
        if (!config)
            return undefined;

        return {
            assemblyProbingPaths: config.get('assemblyProbingPaths', ['.netpackages']),
            packageCachePath: config.get('packageCachePath', '.alpackages')
        };
    }
}

export interface AlExtensionConfig
{
    assemblyProbingPaths: string[];
    packageCachePath: string;
}