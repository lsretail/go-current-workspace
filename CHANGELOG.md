# Change Log
All notable changes to the "LS Retail Update Service Workspace" extension will be documented in this file.

## [1.7.2]
### Changed
- Added .bclicense to license dialog when creating a new project.
- The resolve package version, variable function, now includes the package to resolve, in case it is an optional dependency.

## [1.7.0]
### Added
- Added a variable function to resolve package version from a package ID and version query, in gocurrent.json.
- Support chaining of variable functions, ${variable:func1:func2:func3}
- Added variable functions: *NextMajor*, *CurrentMajor*, *NextMinor*, *CurrentMinor*, *NextPatch*, *NextPreRelease*.

## [1.6.3]
### Changed
- The ability to remove dependency at compile time has been added through compile modifiers, by adding version for a package to 'skip'.

## [1.6.2]
### Changed
- Use correct Business Central management cmdlet path after move in 22.0.

## [1.6.0]
### Added
- A new command, *Import License*, to allow importing a license file to an instance assigned to a project.

## [1.5.0]
### Added
- A new property now available on *gocurrent.json*, *alIncludeServerAssemblies*, to specify if Business Central service-tier assemblies are required when compiling the AL app.
- Now, a local package (.zip file) can be specified in *packages* under *devPackageGroup*.

## [1.4.0]
### Added
- A new command called *Manage Installs* that offers the following management operations:
    - Assign an install to a specific package group in *gocurrent.json*
        - This allows the user to add or remove packages (apps) from the current installation, for example, to add the Business Central test suite packages.
    - Check for updates for individual install.
    - Remove installation.
- *Download Dependencies* now has an option to download dependencies for all projects in the workspace.
- *Compile and Create Package* now has an option to select one or more projects in the workspace, which compiles the projects in dependency order.
- A notification, *Import to Server*, now pops up when a package is created, offering the user to import the newly created package to a server.
### Changes
- The *Remove Packages* command was removed in favor of the new *Manage Installs*.
### Fixed
- When checking for updates for multiple installations and one had an error, it would stop checking for updates for the remaining installs.

## [1.3.0]
### Changes
- *Download dependencies (.alpackages + .netpackage)* changed accordingly:
    - Will not download other apps included in the VS Code workspace.
    - If a dependency has *propagateDependencies* set to true, its dependencies will also download.
    - Apps are renamed to the form *PUBLISHER_NAME_VERSION* when placed into the *.alpackages* directory.

## [1.2.2]
### Changes
- Added the new *ls-central-system-app* to the *app-id-to-package-id* map.
### Fixed
- Extension not activated after *LS Update Service: Go!*.
- Incorrect version query format resulted in a *No updates availble* message, now tells which package has the invalid query.

## [1.2.1]
### Fixed
- Error running AL operations, such as *LS Update Service: Unpublish*.
- Error notifications are sometimes displayed twice.
- Cryptic error notifications [Object].

## [1.2.0]
### Changed
- Support for the new parameter -UpdateInstanceMode Replace|Merge in Install-GocPackage (v0.19.0). New property added to package groups called *updateInstanceMode* and the default value is *Replace*.
### Fixed
- Errors thrown by the extension if Go Current isn't installed on the machine, now informs the user with a notification.
- Multiple notifications for each instance on startup.

## [1.1.0] - 2020-12-14
### Added
- Re-use development package groups from other projects, with a new VS Code setting *devPackageGroupWorkspaceDirs*.
- Update multiple *launch.json* files for AL projects with *devPackageGroupWorkspaceDirs* set.
- You can now turn on debug logs in the VS Code settings. The logs will appear in output-tab (CTRL+SHIFT+U), under *LS Update Service Debug*.

### Changed
- All references to *Go Current* in the user interface have been changed to *LS Update Service*.
- *Compile and create package* now includes AL compilation errors output if any.

### Fixed
- Now, when you right-click on *gocurrent.json->Import dependencies from app.json* it doesn't ask the user which workspace to use, rather uses the workspace where *gocurrent.json* is located.
- If *application* property was set in *app.json*, *gocurrent.json->Import dependencies from app.json* added multiple *bc-application* dependencies.


## [1.0.0] - 2020-10-20
### Added
- *Download Dependencies (.alpackages + .netpackages)* command added.
- *Start App Data Upgrade* command added.
- *Unpublish App* command added.
- *Compile and Create Package* command added.
- *Create Package* command added.
- Variable functions inside *gocurrent.json* added.
    - ${variableName:parts(3)}, ${variableName:preReleaseLabel}, ${variableName:branchLabel}, ${variableName:maxLength(10)}.
- Variable declarations added.
    - Branch priority filter
- AL specific variables and function added to *gocurrent.json*.
- Support for version targets added to *gocurrent.json*.

## [0.3.1] - 2019-12-16
### Added
- Version resolver now supports target configuration, i.e. for release, release candidate or development.

## [0.3.0] - 2019-09-16
### Added
- Added dependencies, package metadata, reference from package group to dependencies and more.

## [0.2.0] - 2019-09-16
### Changed
- Adapted to new Go Current version.

## [0.1.0]
- User can remove installed package groups trough *Remove packages* command.
- User prompt to update launch.json when bc-server package installed.
- User prompt with json document with arguments to fill when installing a package requiring arguments.
- Install and update package groups, defined on project level.
- Initial release