# 2020-09-16, source unpackaged deployment
# 2020-09-15, re-authenticate when deploying on sandboxes
# 2020-09-14, small fix for validation
# 2020-09-11, validation fixes, unpackaged source deployment
# 2020-09-10, retrieve uses commitID when package was generated
# 2020-09-07, fix source deployments
# 2020-09-04, fix test classes not running
# 2020-09-03, read packages-dryrun from variable only. Add source deployment
# 2020-09-02, remove unused functions. Add save/read parameters so that deployment is immutable
# 2020-08-31, fix deployment dependency bug where version is read correctly but ID is not
# 2020-08-20, fix concurrency bug
# 2020-08-19, minor fix for package creation email. Fix on semver comparison comparing on strings instead of ints
# 2020-08-18, retrieve from sandbox
# 2020-08-17, Package creation fix, retrieve from sandbox
# 2020-08-14, Minor deployment fixes
# 2020-08-13, Package creation fix
# 2020-08-12, Deployment refactor.
# 2020-08-10, submodule reset fix. Deployment refactor.
# 2020-08-07, packaging fixes. Also refactoring for deployment
# 2020-08-05, fixes in validation
# 2020-08-04, fix for exception thrown when deploying source
# 2020-08-03, use createEnvironment.sh script
# 2020-07-28, clone submodules
# 2020-07-27, hotfixes for RnR validate and deploy
# SFDX Functions -- START

# The output of the sfdx commands when it's a json file is an array of strings
# So we concatenate them all in one single string so that we can parse them as a json object
Function SFDXParseOutputAsJson ($Output)
{
	$sb = New-Object -TypeName System.Text.StringBuilder
    $Output | % { [void]$sb.Append($_) }	
	$outputAsString = $sb.ToString()
	try
	{
		$json = ConvertFrom-Json $outputAsString -ErrorAction Ignore
	}
	catch
	{
		"[SFDXParseOutputAsJson] Error parsing JSON!" | Write-Host
		"[SFDXParseOutputAsJson] Output as string:" | Write-Host
		$outputAsString | Write-Host
	}
    return $json
}

# Auxiliary function. It cleans up temporary deployment folders
Function SFDXGetTemporaryDeploymentFolder_CleanupTempFolders ($basePath)
{
	Set-Location $basePath
	$now = Get-Date
	# Get only the folders which have >24 hours since being created
	Get-ChildItem -Filter "temp-*" -Directory | ? { ($_.CreationTime.AddDays(1).CompareTo($now)) -eq -1 } | % {
		"[SFDXGetTemporaryDeploymentFolder_CleanupTempFolders] Removing temporary folder $_ ..." | Write-Host
		Remove-Item -Path $_ -Force -Recurse -ErrorAction Ignore
	}
}

# Auxiliary function to create the temporary deployment folder if it doesn't exist
# Also returns the temporary deployment folder name
Function SFDXGetTemporaryDeploymentFolder ($basePath)
{
	SFDXGetTemporaryDeploymentFolder_CleanupTempFolders -basePath $basePath
	# deploymentId format: Deployment-143345
	$deploymentId = $OctopusParameters["Octopus.Deployment.Id"]
	$tempDeploymentFolder = "temp-$deploymentId"
	if (-Not (Test-Path "$SFDXRootFolderLocation\$tempDeploymentFolder"))
	{
		"[SFDXGetTemporaryDeploymentFolder] Creating temporary folder $SFDXRootFolderLocation\$tempDeploymentFolder ..." | Write-Host
		New-Item -Path "$SFDXRootFolderLocation\$tempDeploymentFolder" -ItemType Directory | Out-Null
	}
	return $tempDeploymentFolder
}

# Create a temporary SFDX folder to run several sfdx commands
Function SFDXSetupTempSFDXFolder ($param)
{
	$SN = $param.STEP_NUMBER
	$tempDeploymentFolder = SFDXGetTemporaryDeploymentFolder -basePath $SFDXRootFolderLocation
    # Remove previous temp folder, if it already exists  
    if (Test-Path "$SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXTempFolderName" )
    {
    	"[$SN][SFDXSetupTempSFDXFolder.1] Removing $SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXTempFolderName..." | Write-Host
    	Remove-Item "$SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXTempFolderName" -Force -Recurse -ErrorAction Ignore
    }
	if (-Not (Test-Path "$SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXTempFolderName" ))
	{
		New-Item -Path "$SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXTempFolderName" -ItemType "directory"
	}
    
    "[$SN][SFDXSetupTempSFDXFolder.2] Creating temp project in $SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXTempFolderName..." | Write-Host
    Set-Location "$SFDXRootFolderLocation"
	Get-Location | Write-Host
	
	$output = (& cmd /c "sfdx force:project:create --projectname $SFDXTempFolderName 2>&1" )
    if ($param.DEBUG) { 
		"[$SN][SFDXSetupTempSFDXFolder.3] OUTPUT -- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXSetupTempSFDXFolder.3] OUTPUT -- END" | Write-Host 
	}
    Set-Location "$SFDXRootFolderLocation\$SFDXTempFolderName"
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Returns an array with the valid package names
Function SFDXGetValidPackageNames ($param)
{
	$toReturn = @()
	$arrayPackages = ($SFDXPackageAttributes -split ",")
	$arrayPackages | % { 
		$toReturn += ($_ -split "=")[0]
	}
	$param.ValidPackageNames = $toReturn
}

# Returns a dictionary with:
# Key: the package name
# Value: An array with the valid options for this package.
#   source: This package is to be deployed from source into a sandbox
#   package: This package is to be deployed by installing a package into a sandbox
#   validation: This package can be validated in a new scratch org by using createEnvironment.sh file
Function SFDXGetValidPackageData ($param)
{
	$toReturn = @{}
	$arrayPackages = ($SFDXPackageAttributes -split ",")
	$arrayPackages | % {
		$thisArray = @()
		$thisPackage = $_ -split "="
		# If it has elements
		if ($thisPackage[1].length) {
			($thisPackage[1] -split "\|") | % {
				$thisArray += $_
			}
		}
		$toReturn."$($thisPackage[0])" = $thisArray
	}
	$param.ValidPackageData = $toReturn
}

# For each package, we need to know:
# - Its version number
# - A colloquial name "Sales", "Connect", "Core"
# - The actual package name in Salesforce "salesforce-global-core", "salesforce-global-connect" if it's a package. 
#   If it isn't a package, it will be ignored (it can be left as blank in that case)
# - If a package is supposed to be read from source
# For now, we will set them up manually here
# Later on, we could read from a file in the config\ repository to know if this is supposed to be deployed as a package or not
# This could have more metadata, like if we should run tests as well
Function SFDXConfigurePackageInformation ($param)
{
	SFDXGetValidPackageNames $param
	$PackageNames = $param.ValidPackageNames
	$allPackages = @()
	# Initialize all package values
	# name = "Core", packageName = "salesforce-global-core", deploymentType = none|latest|semver|branch
	# deploymentType: 
	#     none = do not deploy. 
	#     latest = deploy latest package version (for deployment only)
	#     semver = deploy specified package version (for deployment only)
	#     branch = deploy specified branch (for validation/source only)
	$PackageNames | % {
		$thisPackage = @{}
		$thisPackageUppercase = $_.substring(0,1).ToUpper() + $_.substring(1)
		$thisPackage.name = $_
		$thisPackage.packageName = "salesforce-global-$_"
		$thisPackage.targetVersion = $param.parameters.$_
		switch -regex ($thisPackage.targetVersion) {
			# If it's semver 1.0.1.2
			"\d+\.\d+\.\d+\.\d+$" {
				$thisPackage.deploymentType = "semver"
				break
			}
			"latest" {
				$thisPackage.deploymentType = "latest"
				break
			}
			"\w+" {
				$thisPackage.deploymentType = "branch"
				break
			}
			default {
				$thisPackage.deploymentType = "none"
			}
		}
		$allPackages += $thisPackage
	}
	
	"[SFDXConfigurePackageInformation] Package information as read from the parameters [allPackages]:" | Write-Host
	$NL = [System.Environment]::NewLine
	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Parameter information</b></h2></p>" + $NL

	$allPackages | % {
		"Name: $($_.name) PackageName: $($_.packageName) TargetVersion: $($_.targetVersion) DeploymentType: $($_.deploymentType)" | Write-Host
		$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Name:</b> $($_.name) "
		$param.HTMLOutput = $param.HTMLOutput + "<b>Target version:</b> $($_.targetVersion) <b>Deployment type:</b> $($_.deploymentType)</li>" + $NL
	}
	$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
	$param.allPackages = $allPackages
}

# Auxiliary function.
# packageList: Dictionary. Each element contains:
#   <key>: package name (salesforce-global-core). For dependent packages not found in devhub, it's the package ID
#   .order: order in which this package is to be installed. 0 is the first package, higher numbers mean installed after this
#   .deploymentType: package OR source (for these, it's always package)
#   .requiredBy: an array of dictionary items. each element contains:
#      [].packageName: salesforce-global-sales (or user)
#      [].version: 1.0.1.8 ==> the version of THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      [].packageId: 04tCo1018 ==> the package ID for THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      This sample element means that salesforce-global-sales requires the salesforce-global-core package at version 1.0.1.8, packageId 04tCo1018
# currentPackage: 
#   "name"="Sales"; 
#   "packageName"="salesforce-global-sales"; 
#   "deploymentType"="semver"; 
#   "targetVersion" = "1.0.1.8"; 
#   "packageId" = "04t1o000000Y6OtAAK"
# preferredOrder: If the element does not exist, at which position it should be added. It should be an INT
# packageRequiringThis: A string. It's either the package name that requires this OR 'user' if this was entered as a parameter
#   eg: salesforce-global-sales (or: user)
Function SFDXPlanDeployment_AddToPackageList ($packageList, $currentPackage, $preferredOrder, $packageRequiringThis, $param)
{
	# NOTE: This might work by modifying the previous allPackages array while iterating through it, but I am unsure about this
	# If the package doesn't exist, add it
	# Common element to be added
	"[SFDXPlanDeployment_AddToPackageList] packageRequiringThis: $packageRequiringThis version: $($currentPackage.targetVersion) packageId: $($currentPackage.packageId) deploymentType: $($currentPackage.deploymentType) packageName: $($currentPackage.packageName) commitID: $($currentPackage.commitID)" | Write-Host
	$requiredBy = @{ "packageName" = $packageRequiringThis; "version" = $currentPackage.targetVersion; "packageId" = $currentPackage.packageId }
	if (-Not ($packageList."$($currentPackage.packageName)"))
	{
		# Add it at the preferredOrder position
		# First, create the element
		$currentPackageElement = @{}
		$currentPackageElement.order = $preferredOrder
		# Get the commitID from $param.DevhubPackagesList
		$devhubPackage = ($param.DevhubPackagesList.result | ? { ($_.Package2Name -eq "$($currentPackage.packageName)") -And ($_.Version -eq "$($currentPackage.targetVersion)") } | Select-Object -First 1)
		if ($devhubPackage) 
		{
			"[SFDXPlanDeployment_AddToPackageList] Package [$($currentPackage.packageName)], version [[$($currentPackage.targetVersion)]] has commitID [$($devhubPackage.Tag)]" | Write-Host
			$currentPackageElement.commitID = $devhubPackage.Tag
		}
		else
		{
			"[SFDXPlanDeployment_AddToPackageList] WARNING - Couldn't find package with name [$($currentPackage.packageName)] and version [$($currentPackage.targetVersion)] on the devhub packages list" | Write-Host
		}
		# If this is a source deployment, then we always need to install it, so we set alreadyInstalled to false
		if ($currentPackage.deploymentType -eq "branch")
		{
			$currentPackageElement.alreadyInstalled = $False
			$currentPackageElement.deployPackageId = $currentPackage.targetVersion
			$currentPackageElement.deploymentType = "source"
		}
		else
		{
			$currentPackageElement.deploymentType = "package"
		}
		$currentPackageElement.requiredBy = @()
		$currentPackageElement.requiredBy += $requiredBy
		# Then, for each element with order >= preferredOrder, add +1 to their order
		$packageList.GetEnumerator() | ? { $_.Value.order -ge $preferredOrder } | % { $_.Value.order++ }
		# Then, insert the element
		$packageList."$($currentPackage.packageName)" = $currentPackageElement
	}
	# If it exists
	else
	{
		$existingPackage = $packageList."$($currentPackage.packageName)"
		$existingPackage.requiredBy += $requiredBy
	}
}

# Auxiliary function. It will set all the package IDs for all the specified packages.
Function SFDXPlanDeployment_SetAllPackageIds ($allPackages, $param)
{
	SFDXSetupTempSFDXFolder -param $param
	"[SFDXPlanDeployment_SetAllPackageIds] Retrieving list of packages from devhub: $SFDXDevHubAlias ..." | Write-Host
	$output = (& cmd /c "sfdx force:package:version:list --targetdevhubusername $SFDXDevHubAlias --verbose --json 2>&1" )
	$devhubPackagesList = SFDXParseOutputAsJson $output
	if ($devhubPackagesList.result) { $param.DevhubPackagesList = $devhubPackagesList }
	
	$allPackages | % {
    	if (($_.deploymentType -ne "semver") -And ($_.deploymentType -ne "latest")) { return } # return inside of ForEach-Object cmdlet ignores the current element (like continue)
		$currentPackage = $_
		"[$SN][SFDXPlanDeployment_SetAllPackageIds.$($currentPackage.name)] PackageName: $($currentPackage.packageName) TargetVersion: $($currentPackage.targetVersion)" | Write-Host
        $latestVersionSoFar = "0.0.0.0"
        $latestPackageId = ""
        $versionFound = $False
        $devhubPackagesList.result | % { 
        	if ($_.Package2Name -eq "$($currentPackage.packageName)") {
            	# If we should only use the latest version, iterate through all versions and keep finding out which is the latest one
                if ($currentPackage.targetVersion -eq "latest") {
                	$result = SFDXCompareStringVersions -Version1 $latestVersionSoFar -Version2 $_.Version
                    # If 1, $latestVersionSoFar is greater. If -1, $_.Version is greater. If 0, both are equal so it doesn't matter
                    # If it's -1, then we can update the latestVersion and latestVersionId
                    if ($result -eq -1) { 
                    	$latestVersionSoFar = $_.Version
                        $latestPackageId = $_.SubscriberPackageVersionId
                    }
                }
				# If we want a specific target version
                else {
                	if ($_.Version -eq $currentPackage.targetVersion) {
						$currentPackage.packageId = $_.SubscriberPackageVersionId
                    	$versionFound = $True
                    }
                }
            }
        }
        # At this point, if we want latest, we should already have the latest version
        # Also, assume that latest version isn't 0.0.0.0
        if ($latestVersionSoFar -ne "0.0.0.0") {
			$currentPackage.packageId = $latestPackageId
			$currentPackage.targetVersion = $latestVersionSoFar # change 'latest' with the correct version!
            $versionFound = $True
        }
        $NL = [System.Environment]::NewLine
        if (-Not ($versionFound)) {
        	"[$SN][SFDXPlanDeployment_SetAllPackageIds.$($currentPackage.packageName)] List of current versions and IDs -- START" | Write-Host 
            $HTMLError = "        <p><h2><b>Deployment error</b></h2></p>" + $NL
            $HTMLError = $HTMLError + "        <p>The specified package version: <b>($($currentPackage.targetVersion))</b> couldn't be found for package with name: <b>($($currentPackage.packageName))</b> </p>"
            $HTMLError = $HTMLError + "List of all versions for specified package name <b>($($currentPackage.packageName))</b> :<ul>" + $NL
            $devhubPackagesList.result | % { 
        		if ($_.Package2Name -eq "$($currentPackage.packageName)") {
            		"Version: $($_.Version) ID: $($_.SubscriberPackageVersionId)" | Write-Host
                    $HTMLError = $HTMLError + "            <li><b>Version:</b> $($_.Version) <b>ID:</b> $($_.SubscriberPackageVersionId) </li>" + $NL
                }
            }
            $HTMLError = $HTMLError + "        </ul>"
            "[$SN][SFDXPlanDeployment_SetAllPackageIds.$($currentPackage.packageName)] List of current versions and IDs -- END" | Write-Host
            $param.HTMLOutput = $param.HTMLOutput + $HTMLError
            $param.ExitStatus = 21
            SFDXSaveHTMLOutputForNextStep -param $param
            "[$SN][SFDXPlanDeployment_SetAllPackageIds.$($currentPackage.packageName)] ERROR - Couldn't find package ID for $($currentPackage.packageName), version $($currentPackage.targetVersion)!" | Write-Host
			return
        }
    }
	"[SFDXPlanDeployment_SetAllPackageIds.2] All packages information:" | Write-Host
	$allPackages | % {
		"name: $($_.name) packageName: $($_.packageName) deploymentType: $($_.deploymentType) targetVersion: $($_.targetVersion) packageId: $($_.packageId)" | Write-Host
	}
}

# Auxiliary function. With the allPackages dictionary populated, the actual package list is generated.
# packageList: Dictionary. Each element contains:
#   <key>: package name (salesforce-global-core). For dependent packages not found in devhub, it's the package ID
#   .order: order in which this package is to be installed. 0 is the first package, higher numbers mean installed after this
#   .deploymentType: package OR source
#   .requiredBy: an array of dictionary items. each element contains:
#      [].packageName: salesforce-global-sales (or user)
#      [].version: 1.0.1.8 ==> the version of THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      [].packageId: 04tCo1018 ==> the package ID for THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      This sample element means that salesforce-global-sales requires the salesforce-global-core package at version 1.0.1.8, packageId 04tCo1018
# currentPackage: 
#   "name"="Sales"; 
#   "packageName"="salesforce-global-sales"; 
#   "deploymentType"="semver"; 
#   "targetVersion" = "1.0.1.8"; 
#   "packageId" = "04t1o000000Y6OtAAK"
# preferredOrder: If the element does not exist, at which position it should be added. It should be an INT
# packageRequiringThis: A string. It's either the package name that requires this OR 'user' if this was entered as a parameter
#   eg: salesforce-global-sales (or: user)
Function SFDXPlanDeployment_CreatePackageList ($allPackages, $param)
{
	$packageList = @{}
	$devhubPackagesList = $param.DevhubPackagesList
	$allPackages | % {
		# These first sentences print the state of the package list to debug		
		"[SFDXPlanDeployment_CreatePackageList.$($_.name)] Package list -- START" | Write-Host
		$packageList.GetEnumerator() | % {
			"Key: $($_.Name) order: $($_.Value.order) requiredBy:" | Write-Host
			$_.Value.requiredBy | % { "    packageName: $($_.packageName) version: $($_.version) packageId: $($_.packageId) " | Write-Host }
		}
		"[SFDXPlanDeployment_CreatePackageList.1.$($_.name)] Package list -- END" | Write-Host
		# First, attempt to add this package to the list
		$basePositionForElement = $packageList.Count
		$basePackageName = $_.packageName
		# packageRequiringThis = "user" because this is not a dependency; it is read from a parameter
		SFDXPlanDeployment_AddToPackageList -packageList $packageList -currentPackage $_ -preferredOrder $basePositionForElement -packageRequiringThis "user" -param $param

		"[SFDXPlanDeployment_CreatePackageList.2.$($_.name)] Package list -- START" | Write-Host
		$packageList.GetEnumerator() | % {
			"Key: $($_.Name) order: $($_.Value.order) deploymentType: $($_.Value.deploymentType) packageName: $($_.Value.packageName) requiredBy:" | Write-Host
			$_.Value.requiredBy | % { "    packageName: $($_.packageName) version: $($_.version) packageId: $($_.packageId)" | Write-Host }
		}
		"[SFDXPlanDeployment_CreatePackageList.$($_.name)] Package list -- END" | Write-Host
		if ($_.deploymentType -eq "branch") { 
			# NOTE: If we ever have some repositories where we want to deploy from source AND we want some packages to be installed first as dependencies 
			# we would need to modify a good part of this function. Right now, the dependency-checking script is doing a soql query 
			# to retrieve the dependencies that a *package* has. This is querying the devhub. 
			# If we wanted to have the same functionaliry for a source deployment then we would have to read
			# from the sfdx-project.json file, parse it and understand the package versions required for this package.
			# This would also mean checking out each of those repositories, on the branch that is to be deployed to read
			# the correct sfdx-project.json file.
			# We can't query the devhub for this information, because the package isn't created yet!
			"[SFDXPlanDeployment_CreatePackageList.$($_.name)] Deployment type is set to source. Skipping dependency validations..." | Write-Host
			# return inside of ForEach-Object cmdlet ignores the current element (like continue)
			return 
		} 
		# Find dependencies for this package
		"[SFDXPlanDeployment_CreatePackageList.$($_.name).1] Finding dependencies for $($_.packageName) ..." | Write-Host
		$queryText = "select Dependencies from SubscriberPackageVersion where id='$($_.packageId)' "
		"[SFDXPlanDeployment_CreatePackageList.$($_.name).2] Running query: sfdx force:data:soql:query --targetusername $SFDXDevHubAlias --usetoolingapi --json --query ""$queryText"" " | Write-Host
		$output = (sfdx force:data:soql:query --targetusername $SFDXDevHubAlias --query "$queryText" --usetoolingapi --json)
		$jsonOutput = SFDXParseOutputAsJson $output
		# If this has dependencies, add them to the packageList
		if ($jsonOutput.result.records.Dependencies.ids)
		{
			$jsonOutput.result.records.Dependencies.ids | % {
				# First, search the dependencyId on the overall packages list. 
				$currentId = $_.SubscriberPackageVersionId
				"[SFDXPlanDeployment_CreatePackageList.$currentId] Searching current Id for $currentId..." | Write-Host
				$thisPackage = ($packagesList.result | ? { $_.SubscriberPackageVersionId -eq "$currentId"})
				$currentDependencyPackage = @{}
				# If it is found, then it is one of our packages.
				if ($thisPackage) {
					"    [SFDXPlanDeployment_CreatePackageList.$currentId] Found $currentId in existing package list!" | Write-Host
					$currentDependencyPackage.name = ($thisPackage.Package2Name -replace "salesforce-global-", "")
					$currentDependencyPackage.packageName = $thisPackage.Package2Name
					$currentDependencyPackage.deploymentType = "semver"
					$currentDependencyPackage.targetVersion = $thisPackage.Version
					$currentDependencyPackage.packageId = $thisPackage.SubscriberPackageVersionId
				}
				# If it is not, try to find it in all the packages returned from the devhub
				else {
					$devhubPackage = $Null
					$devhubPackagesList.result | ? { $_.SubscriberPackageVersionId -eq $currentId } | % {
						$devhubPackage = $_
					}
					# If it was found on the devhub, it's a package that we handle.
					if ($devhubPackage) {
						"    [SFDXPlanDeployment_CreatePackageList.$currentId] Found $currentId in devhub package list!" | Write-Host
						$currentDependencyPackage.name = ($devhubPackage.Package2Name -replace "salesforce-global-", "")
						$currentDependencyPackage.packageName = $devhubPackage.Package2Name
						$currentDependencyPackage.deploymentType = "semver"
						$currentDependencyPackage.targetVersion = $devhubPackage.Version
						$currentDependencyPackage.packageId = $devhubPackage.SubscriberPackageVersionId
					}
					# This is probably a managed package. In any case, it's not in our devhub
					else {				
						# Mimic the package format
						# "name"="Sales"; "packageName"="salesforce-global-sales"; "deploymentType"="semver"; "targetVersion" = "1.0.1.8"; "packageId" = "04t1o000000Y6OtAAK"
						"    [SFDXPlanDeployment_CreatePackageList.$currentId] Couldn't find $currentId ! Assuming it's a managed package..." | Write-Host
						$currentDependencyPackage.name = $currentId
						$currentDependencyPackage.packageName = $currentId
						$currentDependencyPackage.deploymentType = "semver"
						$currentDependencyPackage.targetVersion = "unknown"
						$currentDependencyPackage.packageId = $currentId
					}
				}
				SFDXPlanDeployment_AddToPackageList -packageList $packageList -currentPackage $currentDependencyPackage -preferredOrder $basePositionForElement -packageRequiringThis "$basePackageName" -param $param
				"[SFDXPlanDeployment_CreatePackageList.$currentId] Package list -- START" | Write-Host
				$packageList.GetEnumerator() | % {
					"    Key: $($_.Name) order: $($_.Value.order) requiredBy:" | Write-Host
					$_.Value.requiredBy | % { "        packageName: $($_.packageName) version: $($_.version) packageId: $($_.packageId) " | Write-Host }
				}
				"[SFDXPlanDeployment_CreatePackageList.$currentId] Package list -- END" | Write-Host
			}
		}
	}
	return $packageList
}

# Auxiliary function. Validates if the package list is fine. Adds some attributes to packageList.
# packageList: Dictionary. Each element contains:
#   <key>: package name (salesforce-global-core). For dependent packages not found in devhub, it's the package ID
#   .order: order in which this package is to be installed. 0 is the first package, higher numbers mean installed after this
#   .deploymentType: package OR source (for these, it's always package)
#   .requiredBy: an array of dictionary items. each element contains:
#      [].packageName: salesforce-global-sales (or user)
#      [].version: 1.0.1.8 ==> the version of THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      [].packageId: 04tCo1018 ==> the package ID for THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      This sample element means that salesforce-global-sales requires the salesforce-global-core package at version 1.0.1.8, packageId 04tCo1018
# New attributes added to each element of packageList:
#   .deployPackageId: The correct package ID that we are going to deploy. Empty if there was an error
#   .validationMessage: If there was an error, this will contain the reason why. Else, it will contain why this package ID was chosen.
Function SFDXPlanDeployment_ValidatePackageList ($packageList, $param)
{
	"[SFDXPlanDeployment_ValidatePackageList] Validating package list versions..." | Write-Host
	$NL = [System.Environment]::NewLine
	$HTMLMessage = "        <p><h2><b>Package dependency detail</b></h2></p>" + $NL
			
	$packageList.GetEnumerator() | Sort-Object { $_.Value.order } | % {
		"[SFDXPlanDeployment_ValidatePackageList] Validating versions for $($_.Name)..." | Write-Host
		if ($_.Value.deploymentType -eq "source") {
			"[SFDXPlanDeployment_ValidatePackageList] $($_.Name) is a source package deployment. No need to validate!" | Write-Host
			return # return inside of ForEach-Object cmdlet ignores the current element (like continue)
		}
		$headerLine = "            <li><b>$($_.Name)</b></li>" + $NL
		$headerLine = $headerLine + "            <ul>" + $NL
		$chosenPackageId = ""
		$chosenPackageVersion = ""
		$validationMessage = ""
		$differencesExist = $False
		$userPackage = $False
		$detailLine = "                <ul>" + $NL
		$_.Value.requiredBy | % {
			$processedPackageName = $_.packageName
			if ($processedPackageName -eq "user") { $processedPackageName = "The user requested this as a parameter" }
			# If this is a managed package, or at least a package that wasn't found on the devhub
			if ($_.version -eq "unknown") {
				$chosenPackageId = $_.packageId
				$chosenPackageVersion = "unknown"
				$detailLine = $detailLine + "                    <li><b>Required by: </b>$processedPackageName. <b>Package version: </b>unknown, not found in devhub. <b>Id: </b>$($_.packageId)</li>" + $NL
			}
			else {
				# If nothing is selected yet, pick it up
				if (-Not ($chosenPackageId)) { 
					$chosenPackageId = $_.packageId
					$chosenPackageVersion = $_.version
				}
				# If what is selected isn't the existing package Id, there are differences
				if ($chosenPackageId -ne $_.packageId) { $differencesExist = $True }
				# If it's the user package, override the selection
				# If it's not, we don't care; we only care if all versions match. For this, it is enough to pick the first version we have
				if ($_.packageName -eq "user") { 
					$userPackage = $True
					$chosenPackageId = $_.packageId
					$chosenPackageVersion = $_.version
				}
				$detailLine = $detailLine + "                    <li><b>Required by: </b>$processedPackageName. <b>Package version: </b>$($_.version) <b>Id: </b>$($_.packageId)</li>" + $NL
			}
		}
		$detailLine = $detailLine + "                </ul>" + $NL
		"[SFDXPlanDeployment_ValidatePackageList] chosenPackageId: $chosenPackageId. chosenPackageVersion: $chosenPackageVersion. userPackage: $userPackage. differencesExist: $differencesExist" | Write-Host
		# If differencesExist, then check if userPackage is true or not.
		if (-Not ($differencesExist)) {
			$validationMessage = "OK: All package(s) which depend on this package are using the same package version: " 
			$summaryLine = "                <li><b>Summary: </b>$validationMessage <b>$chosenPackageVersion</b>, id: <b>$chosenPackageId</b></li>" + $NL
			$validationMessage = $validationMessage + "$chosenPackageVersion, id: $chosenPackageId"
			$_.Value.deployPackageId = $chosenPackageId
			"    $validationMessage" | Write-Host
		}
		# If there were differences, BUT user package was found, use it.
		elseif ($userPackage -eq $True) {
			$validationMessage = "WARNING: Some package(s) which depend on this package are using different package versions (see details). "
			$validationMessage = $validationMessage + "However, the user entered the package version to use as a parameter, so that version is being used: " 
			$summaryLine = "                <li><b>Summary: </b>$validationMessage <b>$chosenPackageVersion</b>, id: <b>$chosenPackageId</b></li>" + $NL
			$validationMessage = $validationMessage + "$chosenPackageVersion, id: $chosenPackageId"	
			$_.Value.deployPackageId = $chosenPackageId
			"    $validationMessage" | Write-Host
		}
		# If there were differences, AND user package was not found, then it's an error.
		else {
			$validationMessage = "<font color='red'>ERROR: Some package(s) which depend on this package are using different package versions (see details).</font> "
			$summaryLine = "                <li><b>Summary: </b>$validationMessage</li>" + $NL
			"    $validationMessage" | Write-Host
			$param.ExitStatus = 71 # This is setting up the error
		}
		$_.Value.validationMessage = $validationMessage
		$HTMLMessage = $HTMLMessage + $headerLine + $summaryLine + $detailLine + "        </ul>" + $NL
	}
	# If there was an error validating, at least show the error?
	if ($param.ExitStatus -eq 71)
	{
		$param.HTMLOutput = $param.HTMLOutput + $HTMLMessage
		Set-OctopusVariable -name "HTMLError" -Value "Package version mismatch. Please check the <b>Package dependency detail</b> section for more details."
	}
}

# Function that will recreate the -parameters.txt file so that it uses the exact version used
# instead of 'latest', if that was used, and saves it as an artifact
# We can't delete artifacts unfortunately, so the process which reads the parameter must
# accommodate for this
Function SFDXPlanDeployment_RewriteParameters ($allPackages, $param)
{
	$releaseId = $OctopusParameters['Octopus.Release.Id']
	$list = SFDXRetrieveArtifacts -OctopusAPIKey $OctopusAPIKey -ServerURL $OctopusServerURL -ReleaseId $releaseId
	$parametersFile = ($list | ? { $_.Filename -match "parameters-parsed.txt" } )
	if ($parametersFile)
	{
		"[SFDXPlanDeployment_RewriteParameters] parameters-parsed.txt file found! No need to rewrite it..." | Write-Host
		return
	}
	"[SFDXPlanDeployment_RewriteParameters] Couldn't find parameters-parsed.txt file. It might be that this file hasn't been created yet (this will happen on DEV)." | Write-Host

	$actualVersionsUsed = ""
	$sep = ""
	# Rebuild the parameters.txt file.
	# Format: <packageName1>=<value1>,<packageName2>=<value2>,<packageName3>=<value3>...
	$allPackages | % {
		$lowercasePackageName = $_.name.ToLower()
		"[SFDXPlanDeployment_RewriteParameters] Adding $lowercasePackageName = $($_.targetVersion)" | Write-Host
		$actualVersionsUsed = $actualVersionsUsed + $sep + "$lowercasePackageName=$($_.targetVersion)"
		$sep = ","
	}
    "[SFDXPlanDeployment_RewriteParameters] Concatenated parameter list: $actualVersionsUsed" | Write-Host
    $tempFile = New-TemporaryFile
    Set-Content -path $tempFile.FullName -value $actualVersionsUsed
    "[SFDXPlanDeployment_RewriteParameters] Contents from temporary file in $($tempFile.FullName) :" | Write-Host
    Get-Content -path $tempFile.FullName
    $releaseId = $OctopusParameters['Octopus.Release.Id']
	"[SFDXPlanDeployment_RewriteParameters] Saving $releaseId-parameters-parsed.txt..." | Write-Host
    New-OctopusArtifact -Path $tempFile.FullName -Name "$releaseId-parameters-parsed.txt"
}

# Auxiliary function that outputs the package list 
Function SFDXPlanDeployment_OutputPackageList ($packageList)
{
	# Output the package list 
	$packageList.GetEnumerator() | Sort-Object { $_.Value.order } | % {
		$currentPackageOutput = "    "
		if ($_.Value.deploymentType -eq "package") {
			$currentPackageOutput = $currentPackageOutput + "PACKAGE NAME/ID: "
		}
		else {
			$currentPackageOutput = $currentPackageOutput + "SOURCE REPOSITORY NAME: "
		}
		$currentPackageOutput = $currentPackageOutput + "$($_.Key) ORDER: $($_.Value.order) "
		if ($_.Value.deploymentType -eq "package") {
			$currentPackageOutput = $currentPackageOutput + "DEPLOYMENT PACKAGE ID: "
		}
		else {
			$currentPackageOutput = $currentPackageOutput + "BRANCH: "
		}
		$currentPackageOutput = $currentPackageOutput + "$($_.Value.deployPackageId) "
		if ($_.Value.deploymentType -eq "package") {
			$currentPackageOutput = $currentPackageOutput + "VALIDATION MESSAGE: $($_.Value.validationMessage) "
			$currentPackageOutput = $currentPackageOutput + "REQUIRED BY: "
			$_.Value.requiredBy | % {
				$currentPackageOutput = $currentPackageOutput + "$($_.packageName), "
				$currentPackageOutput = $currentPackageOutput + "version $($_.version), "
				$currentPackageOutput = $currentPackageOutput + "package ID $($_.packageId)"
			}
		}
		$currentPackageOutput | Write-Host
	}
}

# This function will read the packages that the user intended to deploy.
# For each package, it will then extract their dependencies
# Hopefully I should be able to tell if two or more packages are using different versions of the same shared package.
Function SFDXPlanDeployment ($param, $allPackages)
{
	# allPackages is an array of package:
	# name = "Core", packageName = "salesforce-global-core", deploymentType = none|latest|semver|branch, targetVersion = (branch|packageVer)
	# Fields: BuildNumber (M.m.p.BN), Dependencies [array], Description, IsBeta, IsDeprecated, MajorVersion, MinorVersion, Name, PatchVersion, ReleaseState, SubscriberPackageId
	
	# 1. Set packageIds in allPackages dictionary
	SFDXPlanDeployment_SetAllPackageIds -allPackages $allPackages -param $param
	$environmentName = $OctopusParameters["Octopus.Environment.Name"]
	# The user inputs the parameters in the DEV environment only. For higher environments they are supposed to be read from the .txt file artifact
	# However, the user may have entered 'latest' as the requested package version, so we must replace it with the actual latest version
	# If we don't do this, then every time a deployment is promoted, it will pick up the latest package version and thus
	# the deployment won't be truly immutable
	SFDXPlanDeployment_RewriteParameters -allPackages $allPackages -param $param
	if ($param.ExitStatus -ne 0)
	{
		return
	}
	# At this point in time, $allPackages array contains these values, for each element:
	# "name"="Sales"; "packageName"="salesforce-global-sales"; "deploymentType"="semver"; "targetVersion" = "1.0.1.8"; "packageId" = "04t1o000000Y6OtAAK"
	# 2. Create the actual package list with ordering
	$packageList = SFDXPlanDeployment_CreatePackageList -allPackages $allPackages -param $param
	# 3. Validate the package list to see if there are mismatched versions
	SFDXPlanDeployment_ValidatePackageList -packageList $packageList -param $param
	SFDXPlanDeployment_OutputPackageList -packageList $packageList
	$param.packageList = $packageList
}

# Gets the installed packages from the sandbox
Function SFDXGetInstalledPackages ($OrgAlias, $param)
{
	$output = (& cmd /c "sfdx force:package:installed:list --targetusername $OrgAlias --json 2>&1" )
	$installedPackages = SFDXParseOutputAsJson $output
	$param.InstalledPackages = $installedPackages
}

# Verifies if the planned packages in the packageList are already installed
# packageList: Dictionary. Each element contains:
#   <key>: package name (salesforce-global-core). For dependent packages not found in devhub, it's the package ID
#   .order: order in which this package is to be installed. 0 is the first package, higher numbers mean installed after this
#   .deploymentType: package OR source
#   .requiredBy: an array of dictionary items. each element contains:
#      [].packageName: salesforce-global-sales (or user)
#      [].version: 1.0.1.8 ==> the version of THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      [].packageId: 04tCo1018 ==> the package ID for THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      This sample element means that salesforce-global-sales requires the salesforce-global-core package at version 1.0.1.8, packageId 04tCo1018
#   .deployPackageId: The correct package ID that we are going to deploy. Empty if there was an error
#   .validationMessage: If there was an error, this will contain the reason why. Else, it will contain why this package ID was chosen.
#   .alreadyInstalled: True if this is already on the sandbox, false otherwise
Function SFDXVerifyInstalledPackages ($installedPackages, $packageList)
{
	"[SFDXVerifyInstalledPackages] Verifying if packages to install are already installed in the sandbox..." | Write-Host
	# Only verify for packages! For source, we should always install because we don't have any way of knowing
	$packageList.GetEnumerator() | ? { $_.Value.deploymentType -eq "package" } | % {
		$currentPackage = $_.Value
		$installedPackage = ($installedPackages.result | ? { $_.SubscriberPackageVersionId -eq $currentPackage.deployPackageId })
		if ($installedPackage) {
			$toHost = "[SFDXVerifyInstalledPackages.$($currentPackage.deployPackageId)] Package $($installedPackage.SubscriberPackageName)" + `
				", version $($installedPackage.SubscriberPackageVersionNumber) already installed!"
			$toHost | Write-Host
			$currentPackage.alreadyInstalled = $True
		}
		else {
			"[SFDXVerifyInstalledPackages.$($currentPackage.deployPackageId)] Package isn't installed yet!" | Write-Host
			$currentPackage.alreadyInstalled = $False
		}
	}
	
	"[SFDXVerifyInstalledPackages] packageList -- START" | Write-Host
	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Deployment plan</b></h2></p><ul>" + $NL
	# Sort the packageList by order
	$packageList.GetEnumerator() | Sort-Object { $_.Value.order } | % {
		"    Key: $($_.Key) Order: $($_.Value.order) DeployPackageId: $($_.Value.deployPackageId)" | Write-Host
		"        Validation message: $($_.Value.validationMessage)" | Write-Host
		"        AlreadyInstalled: $($_.Value.alreadyInstalled) CommitID: $($_.Value.commitID) Required by:" | Write-Host
		if ($_.Value.deploymentType -eq "package") {
			$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Package name/id: </b>$($_.Key)<ul>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Installation order: </b>$($_.Value.order)</li>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Deployment package id: </b>$($_.Value.deployPackageId)</li>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Version validation: </b>$($_.Value.validationMessage)</li>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Already installed on sandbox: </b>$($_.Value.alreadyInstalled). "
			if ($_.Value.alreadyInstalled -eq "True") {
				$param.HTMLOutput = $param.HTMLOutput + "This package will not be installed again.</li>" + $NL
			}
			else {
				$param.HTMLOutput = $param.HTMLOutput + "This package will be installed.</li>" + $NL
			}
			
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Why is this package on the installation list?</b><ul>" + $NL
			$_.Value.requiredBy | % {
				"            packageName: $($_.packageName) version: $($_.version) packageId: $($_.packageId)" | Write-Host
				# If this was required by "user", it is a parameter
				if ($_.packageName -eq "user") {
					$param.HTMLOutput = $param.HTMLOutput + "                    <li>Requested by the user as a parameter. "
				}
				else {
					$param.HTMLOutput = $param.HTMLOutput + "                    <li>Required by the <b>$($_.packageName)</b> package. "
				}
				$param.HTMLOutput = $param.HTMLOutput + "Version required: <b>$($_.version)</b>. Package id for required version: <b>$($_.packageId)</b></li>" + $NL
			}
		}
		elseif ($_.Value.deploymentType -eq "source") {
			$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Repository name: </b>$($_.Key)<ul>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Installation order: </b>$($_.Value.order)</li>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Branch: </b>$($_.Value.deployPackageId)</li>" + $NL			
			$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Why is this package on the installation list?</b><ul>" + $NL
				"            User entered this as a parameter" | Write-Host
			$param.HTMLOutput = $param.HTMLOutput + "                    <li>Requested by the user as a parameter.</li>"
		}
		$param.HTMLOutput = $param.HTMLOutput + "                </ul></ul>" + $NL
	}
	$param.HTMLOutput = $param.HTMLOutput + "            </ul>" + $NL
	"[SFDXInstallPackages] packageList -- END" | Write-Host
}

# Expects version of type a.b.c.d, where a, b, c and d are all integers
# Returns 0 if they are equal, -1 if version1<version2, 1 if version1>version2
Function SFDXCompareStringVersions ($Version1, $Version2)
{
	$toReturn = 0
	$v1Parts = $Version1 -split "\."
    $v2Parts = $Version2 -split "\."
    for ($i = 0; $i -lt 4; $i++)
    {
		$numberV1 = [int]$v1Parts[$i]
		$numberV2 = [int]$v2Parts[$i]
    	if ($numberV1 -lt $numberV2) 
        { 
        	$toReturn = -1
            break # exit for loop
        } 
        elseif ($numberV1 -gt $numberV2) 
        { 
        	$toReturn = 1
            break # exit for loop
        }
        # If it hasn't exited the loop, it means both values are equal
    }
    $toReturn
}

# Using the parameter values, retrieve the matching package IDs
# Returns a dictionary of packageIDss
Function SFDXRetrievePackageIds ($PackageNames, $param)
{
	SFDXSetupTempSFDXFolder -param $param
    $SN = $param.STEP_NUMBER
	# Call sfdx force:package:version:list to show list of installed packages, then parse it as json
    $output = (& cmd /c "sfdx force:package:version:list --targetdevhubusername $SFDXDevHubAlias --json 2>&1" )
    if ($param.DEBUG) { 
		"[$SN][SFDXRetrievePackageIds.0] OUTPUT: -- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXRetrievePackageIds.0] OUTPUT: -- END" | Write-Host 
	}
    $jsonOutput = SFDXParseOutputAsJson -Output $output
    if (-Not ($jsonOutput))
    {    
        $param.HTMLOutput = $param.HTMLOutput + "<p><h2><b>Deployment error</b></h2></p><ul><li>Couldn't retrieve package IDs from PROD org</li></ul>"
        $param.ExitStatus = 20
        SFDXSaveHTMLOutputForNextStep -param $param
        "[$SN][SFDXRetrievePackageIds.1] ERROR - Couldn't retrieve package IDs!" | Write-Host
		return
    }
    $toReturn = @{}
    
    # Try to find each of the package IDs
    $PackageNames | % {
    	if (-Not ($_.isPackage)) { return } # return inside of ForEach-Object cmdlet ignores the current element (like continue)
    	$currentPackageName = $_.packageName
        $currentTargetVersion = $_.targetVersion
        $currentName = $_.name
		"[$SN][SFDXRetrievePackageIds.1.$currentName] PackageName: $currentPackageName TargetVersion: $currentTargetVersion" | Write-Host
        $latestVersionSoFar = "0.0.0.0"
        $latestPackageId = ""
        $versionFound = $False
        $jsonOutput.result | % { 
        	if ($_.Package2Name -eq "$currentPackageName") {
            	# If we should only use the latest version, iterate through all versions and keep finding out which is the latest one
                if ($currentTargetVersion -eq "latest") {
                	$result = SFDXCompareStringVersions -Version1 $latestVersionSoFar -Version2 $_.Version
                    # If 1, $latestVersionSoFar is greater. If -1, $_.Version is greater. If 0, both are equal so it doesn't matter
                    # If it's not 1, then we can update the latestVersion and latestVersionId
                    if ($result -ne 1) { 
                    	$latestVersionSoFar = $_.Version
                        $latestPackageId = $_.SubscriberPackageVersionId
                    }
                }
                else {
                	if ($_.Version -eq $currentTargetVersion) {
                    	$toReturn."$currentName" = @{"version" = "$($_.Version)"; "id" = "$($_.SubscriberPackageVersionId)"; "packageName" = "$currentPackageName"} 
                        $versionFound = $True
                    }
                }
            }
        }
        # At this point, if we want latest, we should already have the latest version
        # Also, assume that latest version isn't 0.0.0.0
        if ($latestVersionSoFar -ne "0.0.0.0") {
            $toReturn."$currentName" = @{"version" = "$latestVersionSoFar"; "id" = "$latestPackageId"} 
            $versionFound = $True
        }
        $NL = [System.Environment]::NewLine
        if (-Not ($versionFound)) {
        	"[$SN][SFDXRetrievePackageIds.2.$currentPackageName] List of current versions and IDs -- START" | Write-Host 
            $HTMLError = "        <p><h2><b>Deployment error</b></h2></p>" + $NL
            $HTMLError = $HTMLError + "        <p>The specified package version: <b>($currentTargetVersion)</b> couldn't be found for package with name: <b>($currentPackageName)</b> </p>"
            $HTMLError = $HTMLError + "List of all versions for specified package name <b>($currentPackageName)</b> :<ul>" + $NL
            $jsonOutput.result | % { 
        		if ($_.Package2Name -eq "$currentPackageName") {
            		"Version: $($_.Version) ID: $($_.SubscriberPackageVersionId)" | Write-Host
                    $HTMLError = $HTMLError + "            <li><b>Version:</b> $($_.Version) <b>ID:</b> $($_.SubscriberPackageVersionId) </li>" + $NL
                }
            }
            $HTMLError = $HTMLError + "        </ul>"
            "[$SN][SFDXRetrievePackageIds.2.$currentPackageName] List of current versions and IDs -- END" | Write-Host
            $param.HTMLOutput = $param.HTMLOutput + $HTMLError
            $param.ExitStatus = 21
            SFDXSaveHTMLOutputForNextStep -param $param
            "[$SN][SFDXRetrievePackageIds.2.$currentPackageName] ERROR - Couldn't find package ID for $currentPackageName, version $currentTargetVersion!" | Write-Host
			return
        }
    }
    # How to handle non-package installation?
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
	$toReturn
}

# Run command, capture stderr and stdout in separate variables
# https://stackoverflow.com/questions/24222088/capture-program-stdout-and-stderr-to-separate-variables
Function SFDXRunCommandCapturingOutputError ($CommandToRun)
{
	$tempFile = New-TemporaryFile
    $previousEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {	
    	# With SilentlyContinue error messages aren't output
		$stdout = (& cmd /c "$commandToRun " 2>"$($tempFile.FullName)" ) 
    }
    catch {
    	$exception = $_
    }
    $ErrorActionPreference = $previousEAP
    $stderr = Get-Content "$($tempFile.FullName)"
    Remove-Item "$($tempFile.FullName)" -Force -ErrorAction Ignore
    $returnDict = @{}
    $returnDict.Error = $stderr
    $returnDict.Output = $stdout
    $returnDict.Exception = $exception
    $returnDict
}

Function SFDXParseInstallationOutput ($Output, $PackageId, $PackageName, $IsLastPackage, $param)
{
    $NL = [System.Environment]::NewLine
    $SN = $param.STEP_NUMBER
    # If this is the first package being installed
    if ($param.NumberOfAlreadyInstalledPackages -eq 0)
    {
        $param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Package installation details</b></h2></p>" + $NL
        $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
    }
    $json = SFDXParseOutputAsJson -Output $output
    
    # Error when deploying (status = 1)
    if ($json.status -eq 1)
    {
    	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>$PackageName</b> package with ID <b>$PackageId - FAILED</b><br/>" + $NL
        $param.HTMLOutput = $param.HTMLOutput + "            <ul><li>" + $NL
        $messageWithLineCarriage = $json.message -replace "\n", "</li>$NL            <li>"
        $param.HTMLOutput = $param.HTMLOutput + "$messageWithLineCarriage" + "</li></ul>" + $NL
        $param.HTMLOutput = $param.HTMLOutput + "            </li>" + $NL
        $param.ExitStatus = 40
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
        "[$SN][SFDXParseInstallationOutput.1] $PackageName package with ID $PackageId installation failed!" | Write-Host
        "[$SN][SFDXParseInstallationOutput.1] Message: $($json.message)" | Write-Host
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
    }
    elseif ($json.status -eq 0)
    {
    	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>$PackageName</b> package with ID <b>$PackageId - SUCCEEDED</b></li>" + $NL
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
        "[$SN][SFDXParseInstallationOutput.1] $PackageName package with ID $PackageId installation succeeeded!" | Write-Host
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
		"**************************************************************************************************************" | Write-Host
    }
    
    if ($IsLastPackage)
    {
    	$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
    }
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Shows the installed packages on the specified sandbox or scratch org.
# OrgAlias: The alias of the org that we are getting the installed packages from
# PackageIds: An array of package IDs (04t...) that we want to retrieve.
# If you don't send this parameter everything will be shown. No filtering will be applied.
Function SFDXShowInstalledPackages ($OrgAlias, $PackageIds, $param)
{
	$SN = $param.STEP_NUMBER
	$previousLocation = Get-Location
    SFDXSetupTempSFDXFolder -param $param
    "[$SN][SFDXShowInstalledPackages.1] Showing installed packages on org: $OrgAlias..." | Write-Host
    $output = (& cmd /c "sfdx force:package:installed:list --targetusername $OrgAlias --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXShowInstalledPackages.2] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXShowInstalledPackages.2.1] Installed packages output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXShowInstalledPackages.2.1] Installed packages output --- END" | Write-Host 
	}
	"[$SN][SFDXShowInstalledPackages.3] Package IDs to check:" | Write-Host
	$PackageIds | % {
		"    $_" | Write-Host
	}
    if ($output)
    {
    	$json = SFDXParseOutputAsJson -Output $output
        $NL = [System.Environment]::NewLine
        if ($json.status -eq 0)
        {
        	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Package versions on the sandbox after installation</b></h2></p>" + $NL
            $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
			
            $json.result | % {
				$currentPackageId = $_.SubscriberPackageVersionId
				$IsInstalledPackage = $False
				# If we want to filter by packageIds, do the comparison now
				if ($PackageIds) {
					$PackageIds | % {
						if ($currentPackageId -eq $_) { $IsInstalledPackage = $True }
					}
				}
				# If we don't pass this parameter, we are not filtering
				else {
					$IsInstalledPackage = $True
				}
				if ($IsInstalledPackage) { 
					$param.HTMLOutput = $param.HTMLOutput + "            <li><b>$($_.SubscriberPackageName)</b><br/><ul>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Namespace: </b>$($_.SubscriberPackageNamespace)</li>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "                <li><b>ID: </b>$($_.SubscriberPackageVersionId)</li>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Version number: </b>$($_.SubscriberPackageVersionNumber)</li>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "            </ul></li>" + $NL
					"    $($_.SubscriberPackageName) Namespace: $($_.SubscriberPackageNamespace) ID: $($_.SubscriberPackageVersionId) Version number: $($_.SubscriberPackageVersionNumber)" | Write-Host
				}
			}
			
            $param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
        }
    }
    Set-Location $previousLocation
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Shows the installed packages on the specified sandbox or scratch org.
Function SFDXShowInstalledPackages_Old ($OrgAlias, $PackageIds, $param)
{
	$SN = $param.STEP_NUMBER
	$previousLocation = Get-Location
    SFDXSetupTempSFDXFolder -param $param
    "[$SN][SFDXShowInstalledPackages.1] Showing installed packages on org: $OrgAlias..." | Write-Host
    $output = (& cmd /c "sfdx force:package:installed:list --targetusername $OrgAlias --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXShowInstalledPackages.2] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXShowInstalledPackages.2.1] Installed packages output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXShowInstalledPackages.2.1] Installed packages output --- END" | Write-Host 
	}
    if ($output)
    {
    	$json = SFDXParseOutputAsJson -Output $output
        $NL = [System.Environment]::NewLine
        if ($json.status -eq 0)
        {
        	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Installed packages</b></h2></p>" + $NL
            $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
			
            $json.result | % {
				$currentPackageId = $_.SubscriberPackageVersionId
				$IsInstalledPackage = $False
				# Verify if this packageId is one of the packageIDs that we installed
				$PackageIds.Keys | % {
					if ($currentPackageId -eq $PackageIds."$_".id) { $IsInstalledPackage = $True }
				}
				if ($IsInstalledPackage) { 
					$param.HTMLOutput = $param.HTMLOutput + "            <li><b>$($_.SubscriberPackageName)</b><br/><ul>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Namespace: </b>$($_.SubscriberPackageNamespace)</li>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "                <li><b>ID: </b>$($_.SubscriberPackageVersionId)</li>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "                <li><b>Version number: </b>$($_.SubscriberPackageVersionNumber)</li>" + $NL
					$param.HTMLOutput = $param.HTMLOutput + "            </ul></li>" + $NL
					"    $($_.SubscriberPackageName) Namespace: $($_.SubscriberPackageNamespace) ID: $($_.SubscriberPackageVersionId) Version number: $($_.SubscriberPackageVersionNumber)" | Write-Host
				}
			}
			
            $param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
        }
    }
    Set-Location $previousLocation
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Installs the specified packageID.
Function SFDXInstallPackage ($OrgAlias, $PackageId, $PackageName, $IsLastPackage = $False, $param, $dryrun = $False)
{
	$SN = $param.STEP_NUMBER
    "    [$SN][SFDXInstallPackage.1] Installing package with ID $PackageId to org: $OrgAlias" | Write-Host
	$commandToRun = "sfdx force:package:install --package ""$PackageId"" --targetusername ""$OrgAlias"" --upgradetype DeprecateOnly --noprompt --wait 30 --json"
	if ($dryrun -eq "true")
	{
		"[SFDXInstallPackage] DRY RUN --- Command that would be run:" | Write-Host
		"    sfdx force:package:install --package ""$PackageId"" --targetusername ""$OrgAlias"" --upgradetype DeprecateOnly --noprompt --wait 30 --json" | Write-Host
		return
	}
	"[$SN][SFDXInstallPackage.2] Command to run: $commandToRun" | Write-Host
	$output = SFDXRunCommandCapturingOutputError -CommandToRun $commandToRun
	if ($param.DEBUG) { "    [$SN][SFDXInstallPackage.3] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
	if ($param.DEBUG) { 
		"    [$SN][SFDXInstallPackage.3.2] Installation output -- START" | Write-Host
		$output.Output | Write-Host
		"    [$SN][SFDXInstallPackage.3.2] Installation output -- END" | Write-Host 
	}
	SFDXParseInstallationOutput -Output $output.Output -PackageId $PackageId -PackageName $PackageName -IsLastPackage $IsLastPackage -param $param
}

# Retrieves the files that we are going to deploy, just before deployment.
# After retrieving them they are saved as artifacts in Octopus Deploy.
# packageList: Dictionary. Each element contains:
#   <key>: package name (salesforce-global-core). For dependent packages not found in devhub, it's the package ID
#   .order: order in which this package is to be installed. 0 is the first package, higher numbers mean installed after this
#   .requiredBy: an array of dictionary items. each element contains:
#      [].packageName: salesforce-global-sales (or user)
#      [].version: 1.0.1.8 ==> the version of THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      [].packageId: 04tCo1018 ==> the package ID for THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      This sample element means that salesforce-global-sales requires the salesforce-global-core package at version 1.0.1.8, packageId 04tCo1018
#   .deployPackageId: The correct package ID that we are going to deploy. Empty if there was an error
#   .validationMessage: If there was an error, this will contain the reason why. Else, it will contain why this package ID was chosen.
#   .alreadyInstalled: True if this is already on the sandbox, false otherwise
#	.commitID: The commit ID where this package was created from. If source, the commit ID for the branch where we want to deploy from.
Function SFDXRetrieveFromSandbox ($packageList, $OrgAlias, $param)
{
	# $packageList.GetEnumerator() | ? { $_.Value.alreadyInstalled -eq $False } | Sort-Object { $_.Value.order } | % {
	# Temporarily use this, to always retrieve
	$packageList.GetEnumerator() | Sort-Object { $_.Value.order } | % {
		$packageName = $_.Key
		# If it's not a package we control, skip it
		if (-Not ($packageName.StartsWith("salesforce-global-"))) {
			"[SFDXRetrieveFromSandbox] Can't retrieve file list for package: $packageName. Skipping..." | Write-Host
			return # return acts as continue in Foreach-Object loop
		}
		$packageShortName = ($_.Key -replace "salesforce-global-", "")
		$packageNameToUse = $packageShortName.substring(0,1).ToUpper() + $packageShortName.substring(1)
		if ($_.Value.deploymentType -eq "package") {
			"[SFDXRetrieveFromSandbox.$packageName] Using $($_.Value.commitID) commitID for retrieval..." | Write-Host
			SFDXGitUpdateFolder -SFDXFolderName $packageShortName -commitID "$($_.Value.commitID)" -fetchSubmodules $True -param $param		
		}
		elseif ($_.Value.deploymentType -eq "source") {
			"[SFDXRetrieveFromSandbox.$packageName] Using $($_.Value.commitID) branch for retrieval..." | Write-Host
			SFDXGitUpdateFolder -SFDXFolderName $packageShortName -branch "$($_.Value.commitID)" -fetchSubmodules $True -param $param		
		}
		else {
			"[SFDXRetrieveFromSandbox.$packageName] WARNING - Invalid deployment type! Expecting package|source. Actual value: ( $($_.Value.deploymentType) )" | Write-Host
		}
		# Convert the source to mdapi
		if (Test-Path ".\mdapi") {
			"[SFDXRetrieveFromSandbox.$packageName] Removing mdapi folder..." | Write-Host
			Remove-Item -Path ".\mdapi" -Force -Recurse -ErrorAction Ignore
		}
		if (-Not (Test-Path ".\$packageShortName")) {
			[string] $warningString = "[SFDXRetrieveFromSandbox.$packageName] WARNING: .\$packageShortName doesn't exist! Skipping retrieve from sandbox..." 
			Write-Warning $warningString
			return
		}
		"[SFDXRetrieveFromSandbox.$packageName] Converting project to mdapi..." | Write-Host
		$output = (& cmd /c "sfdx force:source:convert --rootdir .\$packageShortName --outputdir .\mdapi --json 2>&1")
		$jsonOutput = SFDXParseOutputAsJson $output
		"[SFDXRetrieveFromSandbox.$packageName] jsonOutput for force:source:convert" | Write-Host
		$jsonOutput
		"=========" | Write-Host
		if (Test-Path ".\rfsMdapi") {
			"[SFDXRetrieveFromSandbox.$packageName] Removing rfsMdapi folder..." | Write-Host
			Remove-Item -Path ".\rfsMdapi" -Force -Recurse -ErrorAction Ignore
		}
		"[SFDXRetrieveFromSandbox.$packageName] Retrieving from sandbox..." | Write-Host
		$output = (& cmd /c "sfdx force:mdapi:retrieve --targetusername $OrgAlias --retrievetargetdir .\rfsMdapi --unpackaged .\mdapi\package.xml --json --verbose 2>&1")
		$jsonOutput = SFDXParseOutputAsJson $output
		"[SFDXRetrieveFromSandbox.$packageName] jsonOutput for force:mdapi:retrieve" | Write-Host
		$jsonOutput
		"=========" | Write-Host
		# Upload .zip file
		if (Test-Path ".\rfsMdapi\unpackaged.zip") {
			$environment = $OctopusParameters['Octopus.Environment.Name']
			$releaseNumber = $OctopusParameters['Octopus.Release.Number']
			"[SFDXRetrieveFromSandbox.$packageName] Saving $environment-$releaseNumber-$packageName-rfs.zip as artifact..." | Write-Host
			New-OctopusArtifact `
				-Path ".\rfsMdapi\unpackaged.zip" -Name `
				"$environment-$releaseNumber-$packageName-rfs.zip"
		}
		else {
			"[SFDXRetrieveFromSandbox.$packageName] ERROR - Couldn't retrieve from the sandbox!" | Write-Host
			$param.ExitStatus = 91
		}
	}
}

# Installs only the required the packages in the orgs. Reorganizes the package list as well.
# packageList: Dictionary. Each element contains:
#   <key>: package name (salesforce-global-core). For dependent packages not found in devhub, it's the package ID
#   .order: order in which this package is to be installed. 0 is the first package, higher numbers mean installed after this
#   .deploymentType: package OR source
#   .requiredBy: an array of dictionary items. each element contains:
#      [].packageName: salesforce-global-sales (or user)
#      [].version: 1.0.1.8 ==> the version of THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      [].packageId: 04tCo1018 ==> the package ID for THIS package (eg Core) that SALES requires (or that the USER specified as parameter)
#      This sample element means that salesforce-global-sales requires the salesforce-global-core package at version 1.0.1.8, packageId 04tCo1018
#   .deployPackageId: The correct package ID that we are going to deploy. Empty if there was an error
#   .commitID: The commit ID for the specified package
#   .validationMessage: If there was an error, this will contain the reason why. Else, it will contain why this package ID was chosen.
#   .alreadyInstalled: True if this is already on the sandbox, false otherwise
Function SFDXInstallPackagesAndDeploySource ($packageList, $OrgAlias, $param)
{
	$atLeastOnePackageInstalled = $False
	# Build the list (technically, an array) of packages for which we want to do the unpackaged source deployment
	$listUnpackagedDeployment = ($param.ValidPackageData.GetEnumerator() | ? { $_.Value -eq "unpackaged" } ).Name
	"listUnpackagedDeployment === START" | Write-Host
	$listUnpackagedDeployment | % { $_ }
	"listUnpackagedDeployment === END" | Write-Host
	$packageList.GetEnumerator() | Sort-Object { $_.Value.order } | % {
		if ($_.Value.alreadyInstalled) {
			"[SFDXInstallPackagesAndDeploySource.$($_.Value.order)] Package with ID: $($_.Value.deployPackageId) already installed! Skipping installation..." | Write-Host
			return # return acts as continue in Foreach-Object loop
		}
		$shortPackageName = ($_.Key -replace "salesforce-global-", "")
		# If this package needs to have its unpackaged folder deployed
		if ($listUnpackagedDeployment -And ($listUnpackagedDeployment -contains $shortPackageName)) {
			"[SFDXInstallPackagesAndDeploySource.$($_.Value.order)] $($_.Key) package ID $($_.Value.deployPackageId) has unpackaged metadata to deploy [shortPackageName: $shortPackageName]. The commit ID to use for installation is [$($_.Value.commitID)]..." | Write-Host
			SFDXDeploySource -OrgAlias $OrgAlias -PackageName $_.Key -branch $_.Value.commitID -param $param -dryrun $SFDXDryRun -DeployUnpackaged $True
			# If source deployment failed, we shouldn't continue
			if ($param.ExitStatus -ne 0) {
				SFDXSaveHTMLOutputForNextStep -param $param
				"[SFDXInstallPackagesAndDeploySource] Error deploying source for package $shortPackageName! ExitStatus: $($param.ExitStatus)"  | Write-Error
				Exit $param.ExitStatus
			}
		}
		if ($_.Value.deploymentType -eq "package") {
			"[SFDXInstallPackagesAndDeploySource.$($_.Value.order)] Package with ID: $($_.Value.deployPackageId) is being installed..." | Write-Host
			SFDXInstallPackage -OrgAlias $OrgAlias -PackageId $_.Value.deployPackageId -PackageName $_.Key -IsLastPackage $False -param $param -dryrun $SFDXDryRun
			# If package installation failed, we shouldn't continue
			if ($param.ExitStatus -ne 0) {
				SFDXSaveHTMLOutputForNextStep -param $param
				"[SFDXInstallPackagesAndDeploySource] Error installing package $shortPackageName! ExitStatus: $($param.ExitStatus)"  | Write-Error
				Exit $param.ExitStatus
			}
		}
		elseif ($_.Value.deploymentType -eq "source") {
			"[SFDXInstallPackagesAndDeploySource.$($_.Value.order)] $($_.Key) branch $($_.Value.deployPackageId) is being deployed..." | Write-Host
			SFDXDeploySource -OrgAlias $OrgAlias -PackageName $_.Key -branch $_.Value.deployPackageId -param $param -dryrun $SFDXDryRun
			# If package installation failed, we shouldn't continue
			if ($param.ExitStatus -ne 0) {
				SFDXSaveHTMLOutputForNextStep -param $param
				"[SFDXInstallPackagesAndDeploySource] Error on source deployment for $shortPackageName! ExitStatus: $($param.ExitStatus)"  | Write-Error
				Exit $param.ExitStatus
			}
		}
		$atLeastOnePackageInstalled = $True
	}
	# As we don't know which package is the last package, we add this manually.
	if ($atLeastOnePackageInstalled)
	{
		$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
	}
} 

Function SFDXInstallPackages_Old ($OrgAlias, $PackageIds, $param)
{
	$SN = $param.STEP_NUMBER
	# Have some iterator where we know which is the last element
    $totalNumberOfPackages = $PackageIds.Keys.Count
    $param.NumberOfAlreadyInstalledPackages = 0
    $PackageIds.Keys | % {
    	$isLastPackage = ($param.NumberOfAlreadyInstalledPackages -eq ($totalNumberOfPackages - 1))
        if ($param.DEBUG) { "[$SN][SFDXInstallPackages] isLastPackage: $isLastPackage. NumberOfAlreadyInstalledPackages: $($param.NumberOfAlreadyInstalledPackages). totalNumberOfPackages - 1: $($totalNumberOfPackages - 1)" | Write-Host }
        SFDXInstallPackage -OrgAlias $OrgAlias -PackageId $PackageIds."$_".id -PackageName "$_" -IsLastPackage $isLastPackage -param $param
        $param.NumberOfAlreadyInstalledPackages  = $param.NumberOfAlreadyInstalledPackages + 1
    }
    if ($param.ExitStatus -eq 40)
    {
    	# Stop trying to run next steps if any package installation failed. ExitStatus and HTMLOutput already set
        SFDXSaveHTMLOutputForNextStep -param $param
        "[$SN][SFDXInstallPackages] At least one package failed installation!" | Write-Host
		return
    }
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

Function SFDXConvertDeployFailureToDict ($Json)
{
    $DEBUG = $False
	$toReturn = @{}
	$Json | % {
		# Initialize problemType if it doesn't exist
		if (-Not ($toReturn."$($_.problemType)")) 
        { 
            $toReturn."$($_.problemType)" = @{} 
            if ($DEBUG) { "**** INIT - $($_.problemType)" | Write-Host }
        }
		if (-Not ($toReturn."$($_.problemType)"."$($_.type)")) 
        { 
            $toReturn."$($_.problemType)"."$($_.type)" = @{} 
            if ($DEBUG) { "**** INIT - $($_.problemType).$($_.type) " | Write-Host }
        }
		if (-Not ($toReturn."$($_.problemType)"."$($_.type)"."$($_.fullName)")) 
		{ 
			$toReturn."$($_.problemType)"."$($_.type)"."$($_.fullName)" = @{}
            if ($DEBUG) { "**** INIT - $($_.problemType).$($_.type).$($_.fullName) " | Write-Host }
			$toReturn."$($_.problemType)"."$($_.type)"."$($_.fullName)".filePath = "$($_.filePath)"
            if ($DEBUG) { "**** INIT - $($_.problemType).$($_.type).$($_.fullName).filePath " | Write-Host }
            # "*** filepath: $_.filePath" | Write-Host
			$toReturn."$($_.problemType)"."$($_.type)"."$($_.fullName)".issues = @()
            if ($DEBUG) { "**** INIT - $($_.problemType).$($_.type).$($_.fullName).issues " | Write-Host }
		}
		$newElement = @{} 
		# Add elements to object if they exist on JSON
		if ("$_.error") { $newElement.error = "$($_.error)" }
		if ($_.columnNumber) { $newElement.columnNumber = $_.columnNumber }
		if ($_.lineNumber) { $newElement.lineNumber = $_.lineNumber }
		$toReturn."$($_.problemType)"."$($_.type)"."$($_.fullName)".issues += $newElement
	}
	$toReturn
}

Function SFDXConvertDeployDictToHTML ($Dict, $NameOfPackage)
{
    $NL = [System.Environment]::NewLine
    $toReturn = "        <p><h2><b>Deployment error log for $NameOfPackage</b></h2></p>" + $NL
    $sep = ""
    $sep2 = ""
    $Dict.GetEnumerator() | sort -Property Name | % {
        $currentProblemType = $_.Name
        $toReturn = $toReturn + "        <p><b>$currentProblemType list</b></p>" + $NL
        $Dict.$currentProblemType.GetEnumerator() | sort -Property Name | % {
            $currentType = $_.Name
			$toReturn = $toReturn + "        <ul>" + $NL
            $toReturn = $toReturn + "            <li><b>$currentType</b></li>" + $NL
			$toReturn = $toReturn + "            <ul>" + $NL
            $Dict.$currentProblemType.$currentType.GetEnumerator() | sort -Property Name | % {
                $currentFullName = $_.Name
                $toReturn = $toReturn + "                <li><b>$currentFullName ($($Dict.$currentProblemType.$currentType.$currentFullName.filePath))</b></li>" + $NL
				$toReturn = $toReturn + "                <ol>" + $NL
                $Dict.$currentProblemType.$currentType.$currentFullName.issues | % {			
					$toReturn = $toReturn + "                    <li><b>"
                    if ($_.lineNumber) { $toReturn = $toReturn + "Line $($_.lineNumber)"; $sep = ", "; $sep2 = ": " }
                    if ($_.columnNumber) { $toReturn = $toReturn + $sep + "Column $($_.columnNumber)"; $sep2 = ": " }
                    $toReturn = $toReturn + $sep2 + "</b>$($_.error)</li>" + $NL
                }
				$toReturn = $toReturn + "                </ol>" + $NL
            }
			$toReturn = $toReturn + "            </ul>" + $NL # This closes the enumeration for all the lines
 			$toReturn = $toReturn + "        </ul>" + $NL # This closes the overall <$currentType
        }
		$toReturn = $toReturn + "        </ul>" + $NL
    }
    $toReturn
}

# Why two different methods for parsing error/success? 
# The internal json structure is different in both cases.
Function SFDXParseErrorOutputFromDeployment ($Output, $PackageName, $param)
{
	$json = SFDXParseOutputAsJson -Output $Output
	$dict = SFDXConvertDeployFailureToDict -Json $json.result
	$html = SFDXConvertDeployDictToHTML -Dict $dict -NameOfPackage $PackageName
    $param.HTMLOutput = $param.HTMLOutput + $html
}

Function SFDXParseSuccessOutputFromDeployment ($Output, $PackageName, $ResultSourceJSONName = "deployedSource", $param)
{
	$NL = [System.Environment]::NewLine
    $SN = $param.STEP_NUMBER
	$json = SFDXParseOutputAsJson -Output $Output
    if ($param.DEBUG) { 
		"[$SN][SFDXParseSuccessOutputFromDeployment.1] json -- START" | Write-Host
		$json.result."$ResultSourceJSONName" | Write-Host
		"[$SN][SFDXParseSuccessOutputFromDeployment.1] json -- END" | Write-Host 
	}
    $param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Deployment log for $PackageName</b></h2></p>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
    $json.result."$ResultSourceJSONName" | % {
    	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>$($_.state) : $($_.type) </b>$($_.fullName) ( $($_.filePath) )</li>" + $NL
    	"[$SN][SFDXParseSuccessOutputFromDeployment] $($_.state) : $($_.type) $($_.fullName) ( $($_.filePath) )" | Write-Host
    }
    $param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Deploys the source to a sandbox
Function SFDXDeploySource ($OrgAlias, $packageName, $param, $branch, $dryrun = $False, $IsScratchOrg = $False, $DeployUnpackaged = $False)
{
	$shortPackageName = ($packageName -replace "salesforce-global-", "")
	SFDXGitUpdateFolder -SFDXFolderName "$shortPackageName" -branch $branch -fetchSubmodules $True -param $param
	$SN = $param.STEP_NUMBER
	"[$SN][SFDXDeploySource.1] Deploying $packageName components from branch $branch on sandbox: $OrgAlias..." | Write-Host
    # On scratch orgs we can use force:source:push because they have change control
	# On sandboxes we need to use force:source:deploy because they don't have change control
	if ($IsScratchOrg)
	{ 
		$jsonNameForResults = "pushedSource"
		$commandToRun = "sfdx force:source:push --targetusername $OrgAlias --json 2>&1"
		if ($dryrun -eq "true")
		{
			"[$SN][SFDXDeploySource.2] DRY RUN --- Nothing is being deployed to the scratch org. Command to run: $commandToRun" | Write-Host
		}
		else
		{
			"[$SN][SFDXDeploySource.2] Deploying source to scratch org. Command to run: $commandToRun" | Write-Host
			$output = (& cmd /c $commandToRun )
		}
	}
	else
	{
		$jsonNameForResults = "deployedSource"
		$tempDeploymentFolder = SFDXGetTemporaryDeploymentFolder -basePath $SFDXRootFolderLocation
		$subfolderName = "$SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName\$shortPackageName"
		# There are two ways this function is called. The first one is when this is part of a package deployment
		# and we must deploy its associated source which is on the unpackaged folder.
		# The second way this function is called is when it's a repository that must be deployed from source
		# such as the salesforce-global-admin repo.
		if ($DeployUnpackaged -eq $True)
		{
			# Search for all the unpackaged-<???> folders, and sort them
			$unpackagedFolderNames = ((Get-ChildItem -Path $subfolderName -Directory -Filter "unpackaged*") | Sort-Object { $_.Name })
			$unpackagedFolderNames | % {
				"[$SN][SFDXDeploySource.2.$($_.Name)] Deploying unpackaged folder $($_.FullName) ..." | Write-Host
				$commandToRun = "sfdx force:source:deploy --runtests TriggerService_Test --testlevel RunSpecifiedTests --targetusername $OrgAlias --sourcepath ""$($_.FullName)"" --json 2>&1"
				if ($dryrun -eq "true")
				{
					"[$SN][SFDXDeploySource.2] DRY RUN --- Nothing is being deployed to the sandbox. Command to run: $commandToRun" | Write-Host
				}
				else
				{
					"[$SN][SFDXDeploySource.2] Changing location to $SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName ..." | Write-Host
					Set-Location "$SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName"
					"[$SN][SFDXDeploySource.2] Deploying source to sandbox. Command to run: $commandToRun" | Write-Host
					$output = (& cmd /c $commandToRun )
				}
			}
		}
		# When it's a source deployment, like for salesforce-global-admin
		else
		{
			"[$SN][SFDXDeploySource.2] Deploying unpackaged source folder $($_.FullName) ..." | Write-Host
			#Original code for this is commented out as it does the entire directory and the new code only does detected changes
			#$commandToRun = "sfdx force:source:deploy --targetusername $OrgAlias --sourcepath ""$subfolderName"" --json 2>&1"
			if ($dryrun -eq "true")
			{
				"[$SN][SFDXDeploySource.2] DRY RUN --- Nothing is being deployed to the sandbox. Command to run: $commandToRun" | Write-Host
			}
			else
			{
				"[$SN][SFDXDeploySource.2] Changing location to $SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName ..." | Write-Host
				Set-Location "$SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName"
				"[$SN][SFDXDeploySource.2] Get current git commit ..." | Write-Host
				$result = Invoke-Git 'log -1 --format=format:"%H"'
				#Remove the 0 at the end resulting from using the git wrapper
				$currentSHA1 = ($result -split " ")[0]
				Write-Host "Current SHA1 : $currentSHA1"
				"[$SN][SFDXDeploySource.2] Get changed files ..." | Write-Host
				$changes = $(git diff-tree --no-commit-id --name-only -r $currentSHA1)
				Write-Host "Changes : $changes"
				"[$SN][SFDXDeploySource.2] Join changed files ..." | Write-Host
				$join = $($changes -join ",")
				Write-Host "Join result : $join"
				"[$SN][SFDXDeploySource.2] Set parameters for sfdx ..." | Write-Host
				$params  = "force:source:deploy --targetusername sfdxbau1dev --sourcepath '$join' --json 2>&1"
				Write-Host "Parameters : $params"
				"[$SN][SFDXDeploySource.2] Deploy changed files ..." | Write-Host
				$output = Invoke-Expression "& `"sfdx`" $params"

				#"[$SN][SFDXDeploySource.2] Changing location to $SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName ..." | Write-Host
				#Set-Location "$SFDXRootFolderLocation\$tempDeploymentFolder\$shortPackageName"
				#"[$SN][SFDXDeploySource.2] Deploying source to sandbox. Command to run: $commandToRun" | Write-Host
				#$output = (& cmd /c $commandToRun )
			}
		}
	}
	
	if ($dryrun -eq "true")
	{
		"[$SN][SFDXDeploySource.3] DRY RUN --- Skipping parsing output as nothing has been deployed" | Write-Host
		return
	}

    if ($param.DEBUG) { "[$SN][SFDXDeploySource.4] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
	if ($param.DEBUG) { 
		"[$SN][SFDXDeploySource.4.1] Deployment output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXDeploySource.4.1] Deployment output --- END" | Write-Host 
	}
    # Deployment error
    if ($LASTEXITCODE -eq 1)
    {
    	$currentHTMLOutput = SFDXParseErrorOutputFromDeployment -Output $output -PackageName "$packageName" -param $param
		"[$SN][SFDXDeploySource.5] Deployment error output -- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXDeploySource.5] Deployment error output -- END" | Write-Host
		$param.HTMLOutput = $param.HTMLOutput + $currentHTMLOutput
        $param.ExitStatus = 52
        SFDXSaveHTMLOutputForNextStep -param $param
        "[$SN][SFDXDeploySource.4] Deployment failed!" | Write-Host
		return
    }
    elseif ($LASTEXITCODE -eq 0)
    {
    	"[$SN][SFDXDeploySource.4] Deployment was successful. Parsing log..." | Write-Host
		# We need to read from json.result.deployedSource (if using force:source:deploy) or .pushedSource (if using force:source:push)
    	SFDXParseSuccessOutputFromDeployment -Output $output -PackageName "$packageName" -ResultSourceJSONName "$jsonNameForResults" -param $param
    }
    if ($param.DEBUG) { 
		"[$SN][SFDXDeploySource.4.1] Deployment output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXDeploySource.4.1] Deployment output --- END" | Write-Host 
	}
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Deploy the source to a sandbox or scratch org
Function SFDXDeploySource_Old ($OrgAlias, $IsScratchOrg, $param, $TestsShouldFail = $False)
{
	SFDXGitUpdateSalesFolder -param $param -TestsShouldFail $TestsShouldFail
    $SN = $param.STEP_NUMBER
    "[$SN][SFDXDeploySource.1] Deploying settings on sandbox: $OrgAlias..." | Write-Host
    $output = (& cmd /c "sfdx force:source:deploy --targetusername $OrgAlias --sourcepath ""$SFDXRootFolderLocation\$SFDXSalesFolderName\sales\commons"" --json 2>&1" )
    if ($LASTEXITCODE -ne 0)
    {
    	"[$SN][SFDXDeploySource.2] sales\commons deployment failed!" | Write-Host
		
		"******1" | Write-Host
		$param.HTMLOutput | Write-Host
		"******2" | Write-Host
        $currentHTMLOutput = SFDXParseErrorOutputFromDeployment -Output $output -PackageName "Sales\commons" -param $param
		$param.HTMLOutput = $param.HTMLOutput + $currentHTMLOutput
        $param.ExitStatus = 51
        SFDXSaveHTMLOutputForNextStep -param $param
		return
    }
    else
    {
    	"[$SN][SFDXDeploySource.2] sales\commons deployment was successful!" | Write-Host
    }
    if ($param.DEBUG) { "[$SN][SFDXDeploySource.2] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXDeploySource.2.1] Deployment output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXDeploySource.2.1] Deployment output --- END" | Write-Host 
	}
    
    "[$SN][SFDXDeploySource.3] Deploying sales components on sandbox: $OrgAlias..." | Write-Host
    # On scratch orgs we can use force:source:push because they have change control
	# On sandboxes we need to use force:source:deploy because they don't have change control
	if ($IsScratchOrg)
	{ 
		$jsonNameForResults = "pushedSource"
		$output = (& cmd /c "sfdx force:source:push --targetusername $OrgAlias --json 2>&1" )
	}
	else
	{
		$jsonNameForResults = "deployedSource"
		$output = (& cmd /c "sfdx force:source:deploy --targetusername $OrgAlias --sourcepath ""$SFDXRootFolderLocation\$SFDXSalesFolderName\sales"" --json 2>&1" )
	}  
	
    if ($param.DEBUG) { "[$SN][SFDXDeploySource.4] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
	if ($param.DEBUG) { 
		"[$SN][SFDXDeploySource.4.1] Deployment output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXDeploySource.4.1] Deployment output --- END" | Write-Host 
	}
    # Deployment error
    if ($LASTEXITCODE -eq 1)
    {
    	$currentHTMLOutput = SFDXParseErrorOutputFromDeployment -Output $output -PackageName "Sales" -param $param
		$param.HTMLOutput = $param.HTMLOutput + $currentHTMLOutput
        $param.ExitStatus = 52
        SFDXSaveHTMLOutputForNextStep -param $param
        "[$SN][SFDXDeploySource.4] Deployment failed!" | Write-Host
		return
    }
    elseif ($LASTEXITCODE -eq 0)
    {
    	"[$SN][SFDXDeploySource.4] Deployment was successful. Parsing log..." | Write-Host
		# We need to read from json.result.deployedSource (if using force:source:deploy) or .pushedSource (if using force:source:push)
    	SFDXParseSuccessOutputFromDeployment -Output $output -PackageName "Sales" -ResultSourceJSONName "$jsonNameForResults" -param $param
    }
    if ($param.DEBUG) { 
		"[$SN][SFDXDeploySource.4.1] Deployment output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXDeploySource.4.1] Deployment output --- END" | Write-Host 
	}
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# This parses the test output and generates the HTML accordingly
# packageName: If passed, shows it on the header
Function SFDXParseTestOutput ($Output, $packageName, $param)
{
	$SN = $param.STEP_NUMBER
	if ($param.DEBUG) { 
		"[$SN][SFDXParseTestOutput.0] output -- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXParseTestOutput.0] output -- END" | Write-Host 
	}
	"[$SN][SFDXParseTestOutput.1] Parsing output (# of lines: $($Output.Length) ) as JSON... " | Write-Host
	$json = SFDXParseOutputAsJson -Output $output
    $summary = $json.result.summary
	$NL = [System.Environment]::NewLine
	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Test run summary" 
	if ($packageName)
	{
		$param.HTMLOutput = $param.HTMLOutput + ": $packageName"
	}
	$param.HTMLOutput = $param.HTMLOutput + "</b></h2></p>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
    if ($summary.outcome -eq "Passed") { $fontColor = "green" } else { $fontColor = "red" }
    $param.HTMLOutput = $param.HTMLOutput + "            <li><font color='$fontColor'><b>Test outcome: </b>$($summary.outcome)</font></li>" + $NL
    $testRanLine = "            <li><b>Tests run: </b>$($summary.testsRan). <b>Passed: </b>$($summary.passing) ( $($summary.passRate) ). "
    $testRanLine = $testRanLine + "<b>Failed: </b>$($summary.failing) ( $($summary.failRate) )."
    $testRanLine = $testRanLine + "<b>Skipped: </b>$($summary.skipped). </li>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + $testRanLine
    $param.HTMLOutput = $param.HTMLOutput + "            <li><b>Coverage: </b>$($summary.testRunCoverage) . <b>Org-wide coverage: </b>$($summary.orgWideCoverage)</li>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + "            <li><b>Test start time: </b>$($summary.testStartTime) . <b>Execution time: </b>$($summary.testExecutionTime) .  <b>Total time: </b>$($summary.commandTime)</li>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Test run details</b></h2></p>" + $NL
    $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
	$testRunSummaryLine = "[$SN][SFDXParseTestOutput.1] Test run summary"
	if ($packageName) 
	{
		$testRunSummaryLine = $testRunSummaryLine + ": $packageName"
	}
	$testRunSummaryLine | Write-Host
    "    Test outcome: $($summary.outcome)" | Write-Host
    "    Tests run: $($summary.testsRan). Passed: $($summary.passing) ( $($summary.passRate) ). " | Write-Host
    "    Failed: $($summary.failing) ( $($summary.failRate) ). Skipped: $($summary.skipped). " | Write-Host
    "    Coverage: $($summary.testRunCoverage) . Org-wide coverage: $($summary.orgWideCoverage)" | Write-Host
    "    Test start time: $($summary.testStartTime) . Execution time: $($summary.testExecutionTime) . Total time: $($summary.commandTime)" | Write-Host
    "    Test run details time: $($summary.testStartTime) . Execution time: $($summary.testExecutionTime) . Total time: $($summary.commandTime)" | Write-Host
    "    Test run details" | Write-Host
    $json.result.tests | % {
    	if ($_.Outcome -eq "Pass") { $fontColor = "green" } else { $fontColor = "red" }
    	$currentTestResult = "            <li><font color='$fontColor'><b>$($_.FullName) : </b>$($_.Outcome). </font><b>Run time: </b> $($_.RunTime)"
        # Append error message if it didn't pass
        if ($_.Outcome -ne "Pass") {
      		$currentTestResult = $currentTestResult + "<br>" + $NL + "            <ul><li><b>Error message: </b>$($_.Message)</li>"
            $currentTestResult = $currentTestResult + "            <li><b>Stack trace: </b>$($_.StackTrace)</li></ul>" + $NL
            $param.ExitStatus = 60
        }
        $currentTestResult = $currentTestResult + "</li>" + $NL
    	$param.HTMLOutput = $param.HTMLOutput + $currentTestResult
        "        $($_.FullName) : $($_.Outcome). Run time: $($_.RunTime)" | Write-Host
        if ($_.Outcome -ne "Pass") { "            Error message: $($_.Message)" | Write-Host; "            Stack trace: $($_.StackTrace)" | Write-Host }
    }
    $param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Parses the code coverage file to check individual methods' code coverage
Function SFDXParseTestCoverage ($TestRunFolder, $param)
{
	$SFDX_CODE_COVERAGE_THRESHOLD = 80
	$SN = $param.STEP_NUMBER
	$NL = [System.Environment]::NewLine
	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Test code coverage summary</b></h2></p>" + $NL
	$jsonResult = ConvertFrom-Json (Get-Content -Raw "$TestRunFolder\test-result-codecoverage.json")
	if (-Not($jsonResult))
	{
		"[$SN][SFDXParseTestCoverage.0] Couldn't parse JSON with test coverage results!" | Write-Host
		$param.HTMLOutput = $param.HTMLOutput + "        <p>Couldn't parse test coverage results.</p>" + $NL
		$param.ExitStatus = 61
		return
	}
	$HasEnoughCodeCoverageAllClasses = $True
	$coverageText = ""
	$coverageForOutput = ""
	$jsonResult | sort -property name | % {
		$HasAdequateCoverageCurrentClass = $True
		if ($_.coveredPercent -lt $SFDX_CODE_COVERAGE_THRESHOLD) { 
			$HasEnoughCodeCoverageAllClasses = $False
			$HasAdequateCoverageCurrentClass = $False
		}
		if ($HasAdequateCoverageCurrentClass) { 
			$fontColor = "green"
			$currentStatusAsText = "PASS"
		} 
		else { 
			$fontColor = "red" 
			$currentStatusAsText = "FAIL"
		}
		$coverageText = $coverageText + "            <li><font color='$fontColor'><b>$($_.name):</b> $($_.coveredPercent)%</font> ($($_.totalCovered)/$($_.totalLines) lines covered)</li>" + $NL
		$coverageForOutput = $coverageForOutput + "    [$currentStatusAsText] $($_.name): $($_.coveredPercent) ($($_.totalCovered)/$($_.totalLines) lines covered)" + $NL
	}
	if ($HasEnoughCodeCoverageAllClasses) {
		$param.HTMLOutput = $param.HTMLOutput + "        <p><b><font color='green'>Code coverage is adequate (>= $($SFDX_CODE_COVERAGE_THRESHOLD)%).</font></b> Coverage details:</p>" + $NL
		$param.HTMLOutput = $param.HTMLOutput + "        <ol>" + $NL
		"[$SN][SFDXParseTestCoverage.1] Code coverage is adequate (>= $($SFDX_CODE_COVERAGE_THRESHOLD)%)" | Write-Host
	}
	else {
		$param.HTMLOutput = $param.HTMLOutput + "        <p><b><font color='red'>Code coverage failure! At least one class has < $($SFDX_CODE_COVERAGE_THRESHOLD)% coverage.</font></b> Coverage details:</p>" + $NL
		$param.HTMLOutput = $param.HTMLOutput + "        <ol>" + $NL
		$param.ExitStatus = 62
		"[$SN][SFDXParseTestCoverage.1] Code coverage failure! At least one class has < $($SFDX_CODE_COVERAGE_THRESHOLD)% coverage." | Write-Host
	}
	$param.HTMLOutput = $param.HTMLOutput + $coverageText
	$param.HTMLOutput = $param.HTMLOutput + "        </ol>" + $NL
	$coverageForOutput | Write-Host
	"[$SN][SFDXParseTestCoverage.1] ---" | Write-Host
}

# Runs the tests for all packages which contain tests
Function SFDXRunTestsForAllPackages ($packageList, $OrgAlias, $param)
{
	$allTestClassNames = ""
	$sep = ""
	$packageList.GetEnumerator() | % {
		# If this package is one of our packages (not a managed package)
		if (-Not ($_.Key.StartsWith("salesforce-global"))) {
			"[SFDXRunTestsForAllPackages.$($_.Key)] Couldn't find tests for package with ID: $($_.Value.deployPackageId) . Skipping..." | Write-Host
			return
		}
		$packageShortName = ($_.Key -replace "salesforce-global-", "")
		"[SFDXRunTestsForAllPackages.$($_.Key)] Adding tests for $packageShortName..." | Write-Host
		SFDXGitUpdateFolder -SFDXFolderName $packageShortName -branch "qa" -fetchSubmodules $True -param $param
		$concatenatedTestClassNames = SFDXRunTests_GetTestClassNames $param
		$allTestClassNames = $allTestClassNames + $sep + $concatenatedTestClassNames
		$sep = ","
	}
	# We have the list of test class names now.
	# We should remove duplicates from this list
	$uniqueTestClassNames = ($allTestClassNames -split ",") | select -Unique
	# We now rebuild the list with non-duplicated values
	$allTestClassNames = ""
	$sep = ""
	$uniqueTestClassNames | % { 
		$allTestClassNames = $allTestClassNames + $sep + $_
		$sep = ","
	}
	"[SFDXRunTestsForAllPackages] Unique test class names: $uniqueTestClassNames" | Write-Host
	# Don't pass package name so that no package will be shown
	SFDXRunTests_RunSpecificTestClassNames -OrgAlias $OrgAlias -param $param -IsSandbox $True -concatenatedTestClassNames $allTestClassNames -dryrun $SFDXDryRun
}

# Auxiliary function. Retrieves the test class names from this repository.
Function SFDXRunTests_GetTestClassNames ($param)
{
	$testClassFiles = Get-ChildItem -Filter "*.cls" -Recurse | % {
		$fileContent = Get-Content "$($_.FullName)"
		if ($fileContent -match "@istest|@testmethod/i") {
			$_.BaseName # Trim .cls from file name
		}
    }
    if ($param.DEBUG) { 
		"[$SN][SFDXRunTests.1] Test classes found -- START" | Write-Host
		$testClassFiles | Write-Host
		"[$SN][SFDXRunTests.1] Test classes found -- END" | Write-Host 
	}
    $concatenatedTestClassNames = ""
    $separator = ""
    $testClassFiles | % { 
    	$concatenatedTestClassNames = $concatenatedTestClassNames + $separator + $_
        $separator = ","
    }
	"[SFDXRunTests_GetTestClassNames] Test classes found: $concatenatedTestClassNames" | Write-Host
	return $concatenatedTestClassNames
}

# Auxiliary function that will run the specified test classes.
# We are separating this from the global test class run to make it possible to run all tests in one go
# OrgAlias: The org where the tests will run
# IsSandbox: If false, will run all tests with code coverage option
# packageName: salesforce-global-sales (this is for reporting purposes)
# dryrun: If set to true, will only print what would be done instead of running the tests 
Function SFDXRunTests_RunSpecificTestClassNames ($OrgAlias, $param, $IsSandbox, $packageName, $concatenatedTestClassNames, $dryrun = $False)
{
	$SFDXTestRunResultsFolder = ".\testRun"
    $SN = $param.STEP_NUMBER
	if (Test-Path "$SFDXTestRunResultsFolder")
    {
    	Remove-Item -Path "$SFDXTestRunResultsFolder" -Force -Recurse -ErrorAction Ignore
    }
    New-Item -Path "$SFDXTestRunResultsFolder" -Force -ItemType Directory
    "[$SN][SFDXRunTests.2] Running test classes ..." | Write-Host
	# If running the tests on a sandbox, run just the subset
	if ($IsSandbox)
	{
		# If no tests are been found
		if ($concatenatedTestClassNames -eq "")
		{
			"[$SN][SFDXRunTests] No tests detected! Skipping test run..." | Write-Host 
			$NL = [System.Environment]::NewLine
			$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Test run summary</b></h2></p>" + $NL
			$param.HTMLOutput = $param.HTMLOutput + "        <p>Tests didn't run. Deployment didn't include any test classes.</p>" + $NL
			return
		}
		$commandToRun = "sfdx force:apex:test:run --targetusername $OrgAlias --classnames ""$concatenatedTestClassNames"" --outputdir ""$SFDXTestRunResultsFolder"" --wait 30 --resultformat json 2>&1"
		"[$SN][SFDXRunTests] Command to run: $commandToRun" | Write-Host
		if ($dryrun -eq "true") 
		{
			"[$SN][SFDXRunTests] DRY RUN --- No tests are actually running!" | Write-Host 
			$output = ""
		}
		else
		{
			$output = (& cmd /c "$commandToRun" )
		}
	}
	# If running on scratch org, run all tests
	else
	{
		$output = (& cmd /c "sfdx force:apex:test:run --targetusername $OrgAlias --outputdir ""$SFDXTestRunResultsFolder"" --codecoverage --wait 30 --resultformat json 2>&1" )
	}
	
	$failedTestArray = @()
	
	# If tests failed on the sandbox, quickly check if this is because some tests don't exist
	if (($LASTEXITCODE -eq 1) -and ($IsSandbox))
	{
		"[$SN][SFDXRunTests] Tests failed! Checking if it's because some tests weren't present on the sandbox..." | Write-Host 
		$jsonOutput = SFDXParseOutputAsJson -output $output
		# If the error happened because some tests don't exist
		if ($jsonOutput.name -eq "InvalidAsyncTestJobNoneFound")
		{
			"[$SN][SFDXRunTests] Tests failed because some tests weren't present on the sandbox. Removing those tests and retrying..." | Write-Host 
			$failedTestArray = ((($jsonOutput.message -split "Invalid ID or name: ")[1]) -split ", ")
			"[$SN][SFDXRunTests] Tests not present in sandbox:" | Write-Host 
			$failedTestArray | Write-Host
			# We need to create an array again from the concatenated test class names
			$allTestsArray = ($concatenatedTestClassNames -split ",")
			# The easiest way to delete elements is probably to create a new array
			$onlyExistingTestsArray = @()
			$allTestsArray | % {
				# If this test isn't in the 'invalid' list, add it back
				if (-Not ($failedTestArray.Contains($_))) {
					$onlyExistingTestsArray += $_
				}
				else {
					"[$SN][SFDXRunTests] Removing $_ from test list..." | Write-Host 
				}
			}
			# Retry test
			"[$SN][SFDXRunTests] List of tests after removal:" | Write-Host 
			$onlyExistingTestsArray | Write-Host
			$concatenatedExistingTests = ""
			$sep = ""
			$onlyExistingTestsArray | % {
				$concatenatedExistingTests = $concatenatedExistingTests + $sep + $_
				$sep = ","
			}
			$commandToRun = "sfdx force:apex:test:run --targetusername $OrgAlias --classnames ""$concatenatedExistingTests"" --outputdir ""$SFDXTestRunResultsFolder"" --wait 30 --resultformat json 2>&1"
			"[$SN][SFDXRunTests] Retry command to run: $commandToRun" | Write-Host
			$output = (& cmd /c "$commandToRun" )
		}
		else
		{
			"[$SN][SFDXRunTests] Failure reason: $($jsonOutput.name). " | Write-Host 
		}
	}
    
	"[$SN][SFDXRunTests.2.1] Parsing output from test classes ..." | Write-Host
    SFDXParseTestOutput -Output $output -packageName $packageName -param $param
	# If the test run failed because some test classes didn't exist
	if ($failedTestArray.Count -gt 0)
	{
		"[$SN][SFDXRunTests.2.1.1] Adding failed test class information to output..." | Write-Host
		$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Test classes not found on sandbox and removed from test run</b></h2></p>" + $NL
		$param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
		$failedTestArray | % {
			$param.HTMLOutput = $param.HTMLOutput + "            <li><font color='blue'><b>$_</b></font></li>" + $NL
		}
		$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
	}
	
	# Code coverage doesn't output anything valid on sandboxes; only on scratch orgs
	if (-Not ($IsSandbox)) 
	{
		"[$SN][SFDXRunTests.2.2] Parsing code coverage on scratch org ..." | Write-Host
		SFDXParseTestCoverage -TestRunFolder $SFDXTestRunResultsFolder -param $param 
		"[$SN][SFDXRunTests.2.2] ---" | Write-Host
	}
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Runs the tests in the sandbox or scratch org
# OrgAlias: The org where the tests will run
# IsSandbox: If false, will run all tests with code coverage option
# packageName: salesforce-global-sales (this is for reporting purposes)
Function SFDXRunTests ($OrgAlias, $param, $IsSandbox, $packageName)
{
	$concatenatedTestClassNames = SFDXRunTests_GetTestClassNames $param
    SFDXRunTests_RunSpecificTestClassNames -OrgAlias $OrgAlias -param $param -IsSandbox $IsSandbox -packageName $packageName `
		-concatenatedTestClassNames $concatenatedTestClassNames
}

# Saves the HTML output for the next step
Function SFDXSaveHTMLOutputForNextStep($param)
{
	$SN = $param.STEP_NUMBER
    if ($param.DEBUG) { 
		"[$SN][SFDXSaveHTMLOutputForNextStep.1] Complete HTML output -- START" | Write-Host
		$param.HTMLOutput | Write-Host
		"[$SN][SFDXSaveHTMLOutputForNextStep.1] Complete HTML output -- END" | Write-Host 
	}
	Set-OctopusVariable -name "HTMLOutput" -value $param.HTMLOutput
    Set-OctopusVariable -name "ExitStatus" -value $param.ExitStatus
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

Function SFDXGitUpdateConfigFolder ($param)
{
	$SN = $param.STEP_NUMBER
    if (-Not (Test-Path "$SFDXRootFolderLocation\$SFDXConfigFolderName"))
    {
    	"[$SN][UpdateConfigFolder.1] Cloning $SFDXGithubConfigServerUrl into $SFDXRootFolderLocation\$SFDXConfigFolderName ..." | Write-Host
        "[$SN][UpdateConfigFolder.1.1] Injecting credentials into URL. Using $GithubUser as user..." | Write-Host
        # Remove github.com from URL
        $BareUrl = $SFDXGithubConfigServerUrl -replace "https://github.com/", ""
        $UrlWithCredentials = "https://${GithubUser}:$GithubToken@github.com"
        $NewURL = "$UrlWithCredentials/$BareUrl"
        Set-Location $SFDXRootFolderLocation
        Invoke-Git "clone --recurse-submodules --remote-submodules $NewURL $SFDXConfigFolderName"
    }
    Set-Location "$SFDXRootFolderLocation\$SFDXConfigFolderName"
    "[$SN][UpdateConfigFolder.2] Resetting $SFDXConfigFolderName repository..." | Write-Host
    Invoke-Git "fetch" 
	Invoke-Git "reset --hard HEAD"
    # This might have to be hardcoded somewhere. 
    # Alternative: Retrieve master, and dynamically replace the email value with ci-adminteam-email.
    Invoke-Git "branch -D citest" 
    Invoke-Git "checkout -b citest origin/citest"
	Invoke-Git "submodule update --init --recursive"
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

# Runs the specified executable with the desired argument list.
# execPath: Full path to the executable
# argumentList: The list of arguments to pass to the executable, as an array
# initScript: The initialization script to be run before the job starts
# timeoutInSeconds: How long will this wait until it gets bored and stops listening for output
Function SFDXRunExecutableShowOutputRealtime ($execPath, $argumentList, $initScript = $Null, $timeoutInSeconds = 600)
{
	# This is the only syntax I could find that would work with displaying output real-time
	$scriptBlock = {
		& "$using:execPath" $args 
	}
	$job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $argumentList -InitializationScript $initScript

	$wait = 0
	$output = ""
	# This controls the amount of spam sent to the client when no output is seen.
	$MAX_WAIT_UNTIL_FEEDBACK = 10
	"[SFDXRunExecutableShowOutputRealtime] Job information: ID $($job.id). Name $($job.Name). Command: $($job.Command)" | Write-Host
	$waitingForOutput = 0
	while (($wait -lt $timeoutInSeconds) -And ($job.State -ne "Completed"))
	{
		Sleep 1
		try 
		{
			$currentOutput = Receive-Job -Id $job.Id
		}
		catch
		{
			$exceptionAsText = "$_"
			# Ignore this 'error'. It might be outputting to stderr instead of stdout
			if (-Not ($exceptionAsText.trim().StartsWith("SOURCE PROGRESS")))
			{
				"[SFDXRunExecutableShowOutputRealtime] Exception found! -- START" | Write-Host
				# error handling https://stackoverflow.com/questions/38419325/catching-full-exception-message
				$formatstring = "$_`n{0} : {1}`n{2}`n" +
					"    + CategoryInfo          : {3}`n" +
					"    + FullyQualifiedErrorId : {4}`n"
				$fields = $_.InvocationInfo.MyCommand.Name,
						  $_.ErrorDetails.Message,
						  $_.InvocationInfo.PositionMessage,
						  $_.CategoryInfo.ToString(),
						  $_.FullyQualifiedErrorId

				$formatstring -f $fields | Write-Host
				"[SFDXRunExecutableShowOutputRealtime] Exception found! -- END" | Write-Host
			}
		}
		$currentOutput | % { $output = $output + $_ + [System.Environment]::NewLine }
		$currentOutput | Write-Host
		if ($currentOutput) { 
			$waitingForOutput = 0
		}
		else {
			$waitingForOutput = $waitingForOutput + 1
			if ($waitingForOutput -ge $MAX_WAIT_UNTIL_FEEDBACK) { 
				$currentDate = (Get-Date -format "yyyy/MM/dd HH:mm:ss") 
				"[ $currentDate ] *** WAITING FOR OUTPUT *** ($wait / $timeoutInSeconds seconds)" | Write-Host 
				$waitingForOutput = 0
			}
		}
		$wait = $wait + 1
	}
	# Returns the output in the pipeline if caller needs processing
	return $output
}

# Auxiliary function that will convert a CRLF file to LF.
# Works on PowerShell v5+ (build server has 5.1 for the moment)
Function SFDXConvertCRLFtoLF ($filename)
{
	# Get-Content will read line-by-line, with CRLF, CR or LF symbols.
	# Then we add a \n character
	# And the end-of-file needs to have \n.
	((Get-Content $filename) -Join "`n") + "`n" | Set-Content -NoNewLine $filename
}

# This will update the email(s) which are in the file with the specified email
# This is to be used with project-scratch-def.json file
Function SFDXSwitchEmailsOnFile ($pathToFile, $email)
{
	"[SFDXSwitchEmailsOnFile] Replacing emails with $email ..." | Write-Host
	$newFile = @()
	$oldFile = Get-Content -Path $pathToFile 
	$oldFile | % {
		# If it matches word [a-Z0-9_] plus hyphen plus dot, then @ symbol, then the same
		# it's an email address hopefully, so I will replace it.
		if ($_.trim() -match "[\w-\.]*@[\w-\.]*") {
			$newLine = ($_ -replace $matches[0], $email)
			"[SFDXSwitchEmailsOnFile] Email found! ($($matches[0])), replacing ..." | Write-Host
			"[SFDXSwitchEmailsOnFile] Original line: $_" | Write-Host
			"[SFDXSwitchEmailsOnFile] Line after replacement: $newLine" | Write-Host
			$newFile += $newLine
		}
		else {
			$newFile += $_
		}
	}
	Set-Content -Path $pathToFile -Value $newFile
}

# Runs the createEnvironment.sh script for the specified repository
# packageName: surveys, sales
# scratchOrgName: The name of the scratch org. Something like 20200803-1452-surveys
# email: The email of the developer who should receive the package installation notices
Function SFDXRunCreateEnvironmentScript ($packageName, $scratchOrgName, $email, $param)
{
	SFDXGitUpdateFolder -SFDXFolderName $packageName -branch "qa" -fetchSubmodules $True -param $param
	# Get temporary deployment folder name
	$tempDeploymentFolder = SFDXGetTemporaryDeploymentFolder -basePath $SFDXRootFolderLocation
	$folderToSwitchTo = "$SFDXRootFolderLocation\$tempDeploymentFolder\$packageName"
	Set-Location "$folderToSwitchTo"
	# bash requires forward slashes instead of backslashes
	$folderToSwitchTo = ($folderToSwitchTo -Replace "\\", "/")
	$pathToConfigFile = "./config/scratch-org-config/project-scratch-def.json"
	# Just a couple of simple functions. Saved as functions in case we need to reuse them
	SFDXSwitchEmailsOnFile -pathToFile $pathToConfigFile -email $email 
	SFDXConvertCRLFtoLF -filename "./scripts/createEnvironment.sh"
	# Default to 3 days' duration
	# Note that the folder where we run the scripts is sales\ , surveys\ etc. So the config folder is .\config
	$paramAsArray = @("--login", "-c", "cd $folderToSwitchTo; ./scripts/createEnvironment.sh --configpath $pathToConfigFile --setalias $scratchOrgName --targetdevhubusername $SFDXDevHubAlias --durationdays 3 --runfromci")
	$output = SFDXRunExecutableShowOutputRealtime -execPath $SFDXBashPath -argumentList $paramAsArray -timeoutInSeconds 600
	return $output
}

Function SFDXAuthenticateEnvironment ($alias, $token, $param)
{
    SFDXGitUpdateConfigFolder -param $param
    $SN = $param.STEP_NUMBER
    $SFDXConfigScratchOrgJsonFullPath = "$SFDXRootFolderLocation\$SFDXConfigFolderName\$SFDXConfigScratchOrgJsonFilePath"
	$SFDXFolderPath = "$SFDXRootFolderLocation\$SFDXConfigFolderName"
	$previousLocation = Get-Location
	Set-Location $SFDXFolderPath
	"[$SN][SFDXAuthenticateEnvironment.1] Setting location to $SFDXFolderPath... (Previous location: $previousLocation)" | Write-Host
    if (Test-Path temp.txt)
    {
    	Remove-Item "temp.txt" -Force -ErrorAction Ignore
	}
    Set-Content "temp.txt" -Value $token
    
	"[$SN][SFDXAuthenticateEnvironment.2] Authenticating to $alias..." | Write-Host
    $output = (& cmd /c "sfdx force:auth:sfdxurl:store --sfdxurlfile temp.txt --setalias $alias --json 2>&1" )
    Remove-Item "temp.txt" -Force -ErrorAction Ignore
	Set-Location $previousLocation
}

Function SFDXResetPasswordScratchOrg ($scratchOrgName, $param)
{
	"[$SN][SFDXResetPasswordScratchOrg.1] Resetting password for created scratch org: $scratchOrgName ..." | Write-Host
    $output = (& cmd /c "sfdx force:user:password:generate --targetusername $scratchOrgName --targetdevhubusername $SFDXDevHubAlias --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXResetPasswordScratchOrg.1] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXResetPasswordScratchOrg.1.1] Reset output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXResetPasswordScratchOrg.1.1] Reset output --- END" | Write-Host 
	}
    
    $previousLocation = Get-Location
    SFDXSetupTempSFDXFolder -param $param
    "[$SN][SFDXResetPasswordScratchOrg.2] Show details for scratch org $scratchOrgName ..." | Write-Host
    $output = (& cmd /c "sfdx force:user:display --targetusername $scratchOrgName --targetdevhubusername $SFDXDevHubAlias --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXResetPasswordScratchOrg.2] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXResetPasswordScratchOrg.2.1] Details output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXResetPasswordScratchOrg.2.1] Details output --- END" | Write-Host 
	}
	
	$json = SFDXParseOutputAsJson $output
	if (($json -eq $null) -Or ($json -eq ""))
	{
        $param.HTMLOutput = $param.HTMLOutput + "<p><h2><b>Deployment error</b></h2></p><ul><li>Couldn't retrieve information from created scratch org: $scratchOrgName !</li></ul>"
        $param.ExitStatus = 11
        SFDXSaveHTMLOutputForNextStep -param $param
        "[$SN][SFDXResetPasswordScratchOrg.3] ERROR - Couldn't retrieve information from created scratch org: $scratchOrgName !" | Write-Host
		Exit $param.ExitStatus
	}
	$NL = [System.Environment]::NewLine
	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Scratch org information</b></h2></p>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Username:</b> $($json.result.username)</li>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Password:</b> $($json.result.password)</li>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Instance URL:</b> $($json.result.instanceUrl)</li>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
	"[$SN][SFDXResetPasswordScratchOrg.4] Scratch org information:" | Write-Host
	"[$SN][SFDXResetPasswordScratchOrg.4] Username: $($json.result.username)" | Write-Host
	"[$SN][SFDXResetPasswordScratchOrg.4] Password: $($json.result.password)" | Write-Host
	"[$SN][SFDXResetPasswordScratchOrg.4] Instance URL: $($json.result.instanceUrl)" | Write-Host
    Set-Location $previousLocation
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

Function SFDXCreateScratchOrg ($param)
{
    SFDXGitUpdateConfigFolder -param $param
    $SN = $param.STEP_NUMBER
    $SFDXConfigScratchOrgJsonFullPath = "$SFDXRootFolderLocation\$SFDXConfigFolderName\$SFDXConfigScratchOrgJsonFilePath"
    "[$SN][SFDXCreateScratchOrg.0] Authenticating..." | Write-Host
    if (Test-Path temp.txt)
    {
    	Remove-Item "temp.txt" -Force -ErrorAction Ignore
	}
    Set-Content "temp.txt" -Value $SFDXAuthValidateURL
    
    $output = (& cmd /c "sfdx force:auth:sfdxurl:store --sfdxurlfile temp.txt --setalias $SFDXDevHubAlias --json 2>&1" )
    Remove-Item "temp.txt" -Force -ErrorAction Ignore
    if ($param.DEBUG) { "[$SN][SFDXCreateScratchOrg.0] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXCreateScratchOrg.0.1] Authentication output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXCreateScratchOrg.0.1] Authentication output --- END" | Write-Host 
	}
    "[$SN][SFDXCreateScratchOrg.1] Deleting previous scratch org with alias $SFDXScratchOrgAlias..." | Write-Host
    $output = (& cmd /c "sfdx force:org:delete --targetusername $SFDXScratchOrgAlias --noprompt --json 2>&1" )
    if ($LASTEXITCODE -eq 1) # Already deleted
    {
        "[$SN][SFDXCreateScratchOrg.1] $SFDXScratchOrgAlias was already deleted!" | Write-Host
    }
    if ($param.DEBUG) { "[$SN][SFDXCreateScratchOrg.1] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXCreateScratchOrg.1.1] Deletion output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXCreateScratchOrg.1.1] Deletion output --- END" | Write-Host 
	}

    "[$SN][SFDXCreateScratchOrg.2] Creating scratch org with alias $SFDXScratchOrgAlias (Config file located in $SFDXConfigScratchOrgJsonFullPath)..." | Write-Host
    $output = (& cmd /c "sfdx force:org:create --setalias $SFDXScratchOrgAlias --targetdevhubusername $SFDXDevHubAlias --definitionfile ""$SFDXConfigScratchOrgJsonFullPath"" --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXCreateScratchOrg.2] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXCreateScratchOrg.2.1] Creation output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXCreateScratchOrg.2.1] Creation output --- END" | Write-Host 
	}
    
    "[$SN][SFDXCreateScratchOrg.3] Resetting password for created scratch org: $SFDXScratchOrgAlias ..." | Write-Host
    $output = (& cmd /c "sfdx force:user:password:generate --targetusername $SFDXScratchOrgAlias --targetdevhubusername $SFDXDevHubAlias --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXCreateScratchOrg.3] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXCreateScratchOrg.3.1] Reset output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXCreateScratchOrg.3.1] Reset output --- END" | Write-Host 
	}
    
    $previousLocation = Get-Location
    SFDXSetupTempSFDXFolder -param $param
    "[$SN][SFDXCreateScratchOrg.4] Show details for scratch org $SFDXScratchOrgAlias ..." | Write-Host
    $output = (& cmd /c "sfdx force:user:display --targetusername $SFDXScratchOrgAlias --targetdevhubusername $SFDXDevHubAlias --json 2>&1" )
    if ($param.DEBUG) { "[$SN][SFDXCreateScratchOrg.4] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
    if ($param.DEBUG) { 
		"[$SN][SFDXCreateScratchOrg.4.1] Details output --- START" | Write-Host
		$output | Write-Host
		"[$SN][SFDXCreateScratchOrg.4.1] Details output --- END" | Write-Host 
	}
	
	$json = SFDXParseOutputAsJson $output
	if (($json -eq $null) -Or ($json -eq ""))
	{
        $param.HTMLOutput = $param.HTMLOutput + "<p><h2><b>Deployment error</b></h2></p><ul><li>Couldn't retrieve information from created scratch org!</li></ul>"
        $param.ExitStatus = 11
        SFDXSaveHTMLOutputForNextStep -param $param
        "[$SN][SFDXCreateScratchOrg.5] ERROR - Couldn't retrieve information from created scratch org!" | Write-Host
		Exit $param.ExitStatus
	}
	$NL = [System.Environment]::NewLine
	$param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Scratch org information</b></h2></p>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Username:</b> $($json.result.username)</li>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Password:</b> $($json.result.password)</li>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Instance URL:</b> $($json.result.instanceUrl)</li>" + $NL
	$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
	"[$SN][SFDXCreateScratchOrg.6] Scratch org information:" | Write-Host
	"[$SN][SFDXCreateScratchOrg.6] Username: $($json.result.username)" | Write-Host
	"[$SN][SFDXCreateScratchOrg.6] Password: $($json.result.password)" | Write-Host
	"[$SN][SFDXCreateScratchOrg.6] Instance URL: $($json.result.instanceUrl)" | Write-Host
    Set-Location $previousLocation
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

Function SFDXAssignPermissions ($param)
{
	$SN = $param.STEP_NUMBER
	$permissionSetNames = @("Sage_ODS_Views", "Sage_Scratch_Dev",  "Sage_Sales_Admin",  "Sage_Global_Core_Admin",  "Connect_Views")
    $FirstPermissionSetIsAssigned = $False
    $permissionSetNames | % {
    	"[$SN][SFDXAssignPermissions.$_] Assigning permission set $_ ..." | Write-Host
        $permissionSetName = $_
    	$output = (& cmd /c "sfdx force:user:permset:assign --targetusername $SFDXScratchOrgAlias --permsetname ""$_"" --json 2>&1" )
        if ($param.DEBUG) { 
			"[$SN][SFDXAssignPermissions.$_.1] Assignment output -- START" | Write-Host
			$output | Write-Host
			"[$SN][SFDXAssignPermissions.$_.1] Assignment output -- END" | Write-Host 
		}
        if ($output)
        {
        	$NL = [System.Environment]::NewLine
        	if (-Not ($FirstPermissionSetIsAssigned))
            {
            	$FirstPermissionSetIsAssigned = $True
                $param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Permission set assignment details</b></h2></p>" + $NL
                $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
                "[$SN][SFDXAssignPermissions] Permission set assignment details:" | Write-Host
            }
                     
        	$json = SFDXParseOutputAsJson $output
            $json.result.successes | % {
            	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>$($_.value)</b> successfully installed with user <b>$($_.name)</b></li>" + $NL
                "    [$SN][SFDXAssignPermissions.$($_.value)] Successfully intalled permission set with user $($_.name)" | Write-Host
            }
            $AreThereFailures = $False
            $json.result.failures | % {
            	if (-Not ($AreThereFailures))
                {
                	$param.HTMLOutput = $param.HTMLOutput + "            <li><b>Failures for permission set $permissionSetName</b><br/><ul>" + $NL
                    $AreThereFailures = $True
                    "    [$SN][SFDXAssignPermissions.$permissionSetName] Failures for permission set $permissionSetName" | Write-Host
                }
                $param.HTMLOutput = $param.HTMLOutput + "                <li>User <b>$($_.name)</b> : $($_.message) </li>" + $NL
                "        User $($_.name) : $($_.message)" | Write-Host
            }
            if ($AreThereFailures)
            {
            	$param.HTMLOutput = $param.HTMLOutput + "            </ul>" + $NL
            }          
        }
    }
    # If one was assigned, at least
    if ($FirstPermissionSetIsAssigned)
    {
    	$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
    }
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

Function SFDXLoadSetupData ($param)
{
	$SN = $param.STEP_NUMBER
	$dataFilesToImport = @(".\data\CurrencyType.json", ".\data\Account-Contact-Opportunity-plan.json")
    $NL = [System.Environment]::NewLine
    $FirstDataIsLoaded = $False
    $dataFilesToImport | % {
    	"[$SN][SFDXLoadSetupData.$_] Loading data for  $_ ..." | Write-Host
    	$output = (& cmd /c "sfdx force:data:tree:import --targetusername $SFDXScratchOrgAlias --plan ""$_"" --json 2>&1" )
        if ($param.DEBUG) { 
			"[$SN][SFDXLoadSetupData.$_.1] Load output -- START" | Write-Host
			$output | Write-Host
			"[$SN][SFDXLoadSetupData.$_.1] Load output -- END" | Write-Host 
		}

        # If this is the first data being loaded
        if (-Not ($FirstDataIsLoaded))
        {
            $FirstDataIsLoaded = $True
            $param.HTMLOutput = $param.HTMLOutput + "        <p><h2><b>Data load details</b></h2></p>" + $NL
            $param.HTMLOutput = $param.HTMLOutput + "        <ul>" + $NL
            "    [$SN][SFDXLoadSetupData.$_] Data load details:" | Write-Host
        }
        $json = SFDXParseOutputAsJson $output

        # Error when deploying (status = 1)
        if ($json.status -eq 1)
        {
            $param.HTMLOutput = $param.HTMLOutput + "            <li><b>$_</b> data load - FAILED</b><br/>" + $NL
            $brNL = "<br/>" + $NL
            $messageWithLineCarriage = $json.message -replace "\\n", "$brNL"
            $param.HTMLOutput = $param.HTMLOutput + "$messageWithLineCarriage" + "<br/>" + $NL
            $param.HTMLOutput = $param.HTMLOutput + "            </li>" + $NL
            "        Data load failed!" | Write-Host
            "        $($json.message)" | Write-Host
        }
        elseif ($json.status -eq 0)
        {
            $param.HTMLOutput = $param.HTMLOutput + "            <li><b>$_</b> data load - SUCCEEDED</b></li>" + $NL
            "        Data load succeeed!" | Write-Host
        }
    }
    if ($FirstDataIsLoaded)
    {
    	$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
    }
    $param.STEP_NUMBER = $param.STEP_NUMBER + 1
}

Function RunFailedSourceDeployment
{
	$param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $True }
    SFDXValidateParameters -param $param
    SFDXCreateScratchOrg -param $param
    $packageNames = SFDXConfigurePackageInformation -Scenario 101
    $packageIds = SFDXRetrievePackageIds -PackageNames $packageNames -param $param
    if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    SFDXInstallPackages -OrgAlias $SFDXScratchOrgAlias -PackageIds $packageIds -param $param
	if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    SFDXShowInstalledPackages -OrgAlias $SFDXScratchOrgAlias -PackageIds $packageIds -param $param
    # I need to make a generic method that will deploy from source any packages that have isPackage = False
    # For now, I am just putting this out here manually
    SFDXDeploySource -OrgAlias $SFDXScratchOrgAlias -IsScratchOrg $True -param $param -TestsShouldFail $False
    if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    # SFDXAssignPermissions -param $param
    # SFDXLoadSetupData -param $param
    SFDXRunTests -OrgAlias $SFDXScratchOrgAlias -IsSandbox $False -param $param
    SFDXSaveHTMLOutputForNextStep -param $param
}

Function RunFailedPackageDeployment
{
	$param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $True }
    SFDXValidateParameters -param $param
    SFDXCreateScratchOrg -param $param
    $packageNames = SFDXConfigurePackageInformation -Scenario 102
    $packageIds = SFDXRetrievePackageIds -PackageNames $packageNames -param $param
    if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    SFDXInstallPackages -OrgAlias $SFDXScratchOrgAlias -PackageIds $packageIds -param $param
	if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    SFDXShowInstalledPackages -OrgAlias $SFDXScratchOrgAlias -PackageIds $packageIds -param $param
    SFDXGitUpdateSalesFolder -param $param
    # SFDXAssignPermissions -param $param
    # SFDXLoadSetupData -param $param
    SFDXRunTests -OrgAlias $SFDXScratchOrgAlias -IsSandbox $False -param $param
    SFDXSaveHTMLOutputForNextStep -param $param
}

Function RunWithFailedTests
{
	$param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $True }
    SFDXValidateParameters -param $param
    SFDXCreateScratchOrg -param $param
    $packageNames = SFDXConfigurePackageInformation -Scenario 103
    $packageIds = SFDXRetrievePackageIds -PackageNames $packageNames -param $param
    if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    SFDXInstallPackages -OrgAlias $SFDXScratchOrgAlias -PackageIds $packageIds -param $param
    if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    SFDXShowInstalledPackages -OrgAlias $SFDXScratchOrgAlias -PackageIds $packageIds -param $param
    SFDXDeploySource -OrgAlias $SFDXScratchOrgAlias -IsScratchOrg $True -param $param -TestsShouldFail $True
    if ($param.ExitStatus -ne 0) { Exit $param.ExitStatus }
    # SFDXAssignPermissions -param $param
    # SFDXLoadSetupData -param $param
    SFDXRunTests -OrgAlias $SFDXScratchOrgAlias -IsSandbox $False -param $param
    SFDXSaveHTMLOutputForNextStep -param $param
}

Function SFDXRunValidation
{
	# ExitStatus: 
    # 0: Success
    # 11: Error retrieving scratch org information
    # 20: Error retrieving package IDs
    # 21: Error matching desired package version to actual versions
    # 40: Error installing unlocked package
    # 51: Error deploying sales/common source
    # 52: Error deploying sales source
    # 60: Test run failed
	# 61: Couldn't parse code coverage file
	# 62: Code coverage failure
	$param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $False }
	SFDXGetParameterValues -param $param
	SFDXConfigurePackageInformation -param $param
	$allPackages = $param.allPackages
	# HARDCODED: List of end-packages (read from Octopus variable)
	# $SFDXValidationPackages = "sales, surveys"
	# Supposedly, it wouldn't make sense to validate more than one end package.
	# If you trigger this manually then only one of those packages will be validated
	$packageToValidate = ""
	$branchToUseForValidation = ""
	SFDXGetValidPackageData -param $param
	# Loop through the ValidPackageData dictionary
	$listOfValidationPackages = ($param.ValidPackageData.GetEnumerator() | ? { $_.Value -eq "validation" } ).Name
	"[SFDXRunValidation] List of packages allowed for validation -- START" | Write-Host
	$listOfValidationPackages | % { $_ | Write-Host }
	"[SFDXRunValidation] List of packages allowed for validation -- END" | Write-Host
	$allPackages | % {
		"[SFDXRunValidation] Checking deploymentType [$($_.deploymentType)] package [$($_.name)] " | Write-Host
		# $_.name = "surveys", "sales"
		# $_.packageName = "salesforce-global-surveys"
		# $_.deploymentType = "none", "latest", "semver", "branch"
		# Only try to verify those items whose deploymentType = branch (ie, valid values to validate)
		if ($_.deploymentType -eq "branch") {
			$currentName = $_.name
			$currentBranch = $_.targetVersion 
			$listOfValidationPackages | % {
				if ($_.trim() -eq $currentName) {
					# If more than one package matches this, the packageToValidate will get overwritten.
					$packageToValidate = $currentName
					$branchToUseForValidation = $currentBranch
					"[SFDXRunValidation] Found package: $packageToValidate on branch: $branchToUseForValidation" | Write-Host
				}
			}
		}
	}
	
	"[SFDXRunValidation] Selected package: $packageToValidate on branch: $branchToUseForValidation" | Write-Host
	if ((-Not ($packageToValidate)) -Or (-Not ($branchToUseForValidation)))
	{
		$param.HTMLOutput = $param.HTMLOutput + "<p><h2><b>Validation error</b></h2></p><ul><li>Couldn't read package name or branch name to validate</li><li>Alternatively, the package isn't set as able to be validated. List of valid packages for validation: <ul>"
		$listOfValidationPackages | % { 
			$param.HTMLOutput = $param.HTMLOutput + "<li>$_</li>"
		}
		$param.HTMLOutput = $param.HTMLOutput + "</ul></ul>"
		$param.ExitStatus = 82
		SFDXSaveHTMLOutputForNextStep -param $param
		return $param
	}
	
	$scratchOrgName = ((Get-Date -Format "yyyyMMdd-HHmm") + "-$packageToValidate")
	SFDXAuthenticateEnvironment -alias $SFDXDevHubAlias -token $SFDXAuthValidateURL -param $param
	SFDXGitUpdateFolder -SFDXFolderName $packageToValidate -branch $branchToUseForValidation -fetchSubmodules $True -param $param
	# $param.email has the committer email.
	$email = $param.email
	"[SFDXRunValidation] Setting developer email: $email" | Write-Host
	Set-OctopusVariable -name "developerEmail" -value $email
		
	SFDXRunCreateEnvironmentScript -packageName $packageToValidate -scratchOrgName $scratchOrgName -email $email -param $param
	$environmentExitCode = $LASTEXITCODE
	"createEnvironment.sh exit code: $environmentExitCode" | Write-Host
	SFDXResetPasswordScratchOrg -scratchOrgName $scratchOrgName -param $param
	# Not sending the $PackageIds parameter means everything will be shown
    SFDXShowInstalledPackages -OrgAlias $scratchOrgName -param $param
    
    SFDXRunTests -OrgAlias $scratchOrgName -IsSandbox $False -param $param -packageName "salesforce-global-$packageToValidate"
    SFDXSaveHTMLOutputForNextStep -param $param
	return $param
}

Function SFDXRunDeployment
{
    # ExitStatus
    # 0: Success
    # 10: Error validating parameters
    # 20: Error retrieving package IDs
    # 21: Error matching desired package version to actual versions
    # 40: Error installing unlocked package
    # 51: Error deploying sales/common source
    # 52: Error deploying sales source
    # 60: Test run failed
	
    $param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $False }
	SFDXGetParameterValues -param $param
	SFDXConfigurePackageInformation -param $param
	$allPackages = $param.allPackages
	# On here, I should get the packages that have either a package version or 'latest'
	# from there I must reconstruct the actual package versions that need deployment
	# Later I will check and not install a package if it's already there on the sandbox
	"[SFDXRunDeployment] List of actual packages to deploy -- START" | Write-Host
	$packagesToDeploy = @()
	$allPackages | % {
		if (($_.deploymentType -eq "semver") -Or ($_.deploymentType -eq "latest")) {
			$packagesToDeploy += $_
		"    Package: $($_.packageName) Version: $($_.targetVersion)" | Write-Host
		}
		elseif ($_.deploymentType -eq "branch") {
			$packagesToDeploy += $_
		"    Repository: $($_.packageName) Source branch: $($_.targetVersion)" | Write-Host
		}
		
	}
	"[SFDXRunDeployment] List of actual packages to deploy -- END" | Write-Host
	SFDXGetValidPackageData -param $param
	SFDXAuthenticateEnvironment -alias $SFDXSandboxAlias -token $SFDXAuthDeploymentURL -param $param
	SFDXPlanDeployment -param $param -allPackages $packagesToDeploy
	if ($param.ExitStatus -ne 0)
	{
		SFDXSaveHTMLOutputForNextStep -param $param
		"[SFDXRunDeployment] Error validating packages! ExitStatus: $($param.ExitStatus)"  | Write-Error
		Exit $param.ExitStatus
	}
	SFDXGetInstalledPackages -OrgAlias $SFDXSandboxAlias -param $param
	SFDXVerifyInstalledPackages -installedPackages $param.installedPackages -packageList $param.packageList
	SFDXRetrieveFromSandbox -packageList $param.packageList -OrgAlias $SFDXSandboxAlias -param $param
	SFDXInstallPackagesAndDeploySource -packageList $param.packageList -OrgAlias $SFDXSandboxAlias -param $param
	if ($param.ExitStatus -ne 0)
	{
		SFDXSaveHTMLOutputForNextStep -param $param
		if ($param.ExitStatus -eq 71)
		{
			"[SFDXRunDeployment] Package version validation failed!"  | Write-Host
		}
		"[SFDXRunDeployment] Error installing packages! ExitStatus: $($param.ExitStatus)"  | Write-Error
		Exit $param.ExitStatus
	}
	$packageIds = @()
	$param.packageList.GetEnumerator() | ? { $_.Value.deploymentType -eq "package"} | % {
		$packageIds += $_.Value.deployPackageId 
	}
	SFDXShowInstalledPackages -OrgAlias $SFDXSandboxAlias -PackageIds $packageIds -param $param
	SFDXRunTestsForAllPackages -packageList $param.packageList -OrgAlias $SFDXSandboxAlias -param $param
	SFDXSaveHTMLOutputForNextStep -param $param
}

# Gets the folder name where the repository is located
# Also gets the repository URL
Function SFDXGetPackageValues ($packageName)
{
	if (($packageName -eq $null) -Or ($packageName -eq ""))
	{
		"[SFDXGetPackageValues.1] Package name wasn't specified! Value: ( $packageName )" | Write-Host
		Exit 1
	}
	$packageNameLowercase = $packageName.ToLower()
	SFDXGetValidPackageNames $param
	$validValues = $param.ValidPackageNames
	if (-Not ($validValues.Contains($packageNameLowercase)))
	{
		"[SFDXGetPackageValues.2] Invalid package name: ( $packageNameLowercase )" | Write-Host
		"    Was expecting one of these values:" | Write-Host
		$validValues | Write-Host
		Exit 2
	}
	# Repository names are like SFDXGithubConfigServerUrl, SFDXGithubConnectServerUrl, SFDXGithubCoreServerUrl, SFDXGithubSalesServerUrl
	# Folder names are like "$SFDXRootFolderLocation\$SFDXSalesFolderName"
	# https://github.com/Sage/salesforce-global-config.git
	# SFDXSalesFolderName: sales
	$packageNameToUse = $packageNameLowercase.substring(0,1).ToUpper() + $packageNameLowercase.substring(1)
	$SFDXFolderVariableName = "SFDX" + $packageNameToUse + "FolderName"
	$SFDXRepositoryVariableName = "SFDXGithub" + $packageNameToUse + "ServerUrl"
	$SFDXFolderName = Get-Variable -Name $SFDXFolderVariableName -ErrorAction Ignore
	$SFDXRepositoryUrl = Get-Variable -Name $SFDXRepositoryVariableName -ErrorAction Ignore
	if (($SFDXFolderName -eq $Null) -Or ($SFDXRepositoryUrl -eq $Null))
	{
		"[SFDXGetPackageValues.3] Couldn't find variable in library named: $SFDXFolderVariableName / $SFDXRepositoryVariableName !" | Write-Host
		Exit 3
	}
	$toReturn = @{}
	$toReturn.folder = $SFDXFolderName.Value
	$toReturn.repository = $SFDXRepositoryUrl.Value
	"[SFDXGetPackageValues.4.1] folderName: $($SFDXFolderName.Value)" | Write-Host
	"[SFDXGetPackageValues.4.2] repositoryUrl: $($SFDXRepositoryUrl.Value)" | Write-Host
	$toReturn
}

# Clones the specified git repository if it doesn't exist
# If it does, it updates it with the latest
# In both cases, the specified branch is checked out in the end
# SFDXFolderName: sales, surveys, core, config
# SFDXRepositoryUrl: https://github.com/Sage/salesforce-global-sales.git
# branch: The branch to check out
# fetchSubmodules
Function SFDXGitUpdateFolder ($SFDXFolderName, $SFDXRepositoryUrl, $branch = "", $commitID = "", $fetchSubmodules, $param)
{
	# Get the temporary folder name 
	$tempDeploymentFolder = SFDXGetTemporaryDeploymentFolder -basePath $SFDXRootFolderLocation
	Set-Location -Path "$SFDXRootFolderLocation\$tempDeploymentFolder"
	if (-Not (Test-Path "$SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXFolderName"))
    {
		# If this is empty
		if (-Not ($SFDXRepositoryUrl))
		{
			$SFDXRepositoryUrl = "https://github.com/Sage/salesforce-global-$SFDXFolderName.git"
		}
    	"[SFDXGitUpdateFolder.1] Cloning $SFDXRepositoryUrl into $SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXFolderName ..." | Write-Host
        "[SFDXGitUpdateFolder.1.1] Injecting credentials into URL. Using $GithubUser as user..." | Write-Host
        # Remove github.com from URL
        $BareUrl = $SFDXRepositoryUrl -replace "https://github.com/", ""
        $UrlWithCredentials = "https://${GithubUser}:$GithubToken@github.com"
        $NewURL = "$UrlWithCredentials/$BareUrl"
        Set-Location "$SFDXRootFolderLocation\$tempDeploymentFolder"
		$currentLocation = Get-Location
		"[SFDXGitUpdateFolder.1.2] Current Location: $currentLocation" | Write-Host
		Invoke-Git "clone $NewURL $SFDXFolderName"
    }
    Set-Location "$SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXFolderName"
    "[SFDXGitUpdateFolder.2] Resetting $SFDXFolderName repository located in $SFDXRootFolderLocation\$tempDeploymentFolder\$SFDXFolderName..." | Write-Host
    Invoke-Git "fetch" | Write-Host
	Invoke-Git "reset --hard HEAD" | Write-Host
	Invoke-Git "submodule foreach git reset --hard" | Write-Host
    Invoke-Git "checkout qa" | Write-Host
    Invoke-Git "reset --hard origin/qa" | Write-Host
	# If we specified the branch parameter
	if ($branch -ne "")
	{
		# TODO: Check if branch exists!
		Invoke-Git "branch -D $branch" | Write-Host
		Invoke-Git "checkout -b $branch origin/$branch" | Write-Host	
	}
	# If we specified the commit parameter
	elseif ($commit -ne "")
	{
		Invoke-Git "branch -D $commitID" | Write-Host
		Invoke-Git "checkout -b $commitID $commitID" | Write-Host	
	}
    Invoke-Git "pull" | Write-Host
	if ($fetchSubmodules)
	{
		"[SFDXGitUpdateFolder.2.1] Fetching submodules..." | Write-Host
		if (Test-Path ".\.gitmodules")
		{
			"[SFDXGitUpdateFolder.2.2] .\gitmodules file found!" | Write-Host
			$modulesContent = Get-Content ".\.gitmodules"
			# Assume that the file has more than one line.
			for ($i = 0; $i -lt $modulesContent.Length; $i++) 
			{
				# For each URL instance that we find, replace it with username+token format
				if ($modulesContent[$i].Trim().StartsWith("url")) {
					# Search for : and keep just what is after that
					# Sample URL: git@github.com:Sage/salesforce-global-config.git
					$postURL = $modulesContent[$i].split(":")[1]
					$newURL = "https://${GithubUser}:$GithubToken@github.com/$postURL"
					# Now we need to replace the URL. 
					$modulesContent[$i] = "url = $newURL"
				}
			}
			Set-Content -Path ".\.gitmodules" -Value $modulesContent
			(Invoke-Git "submodule sync") | Out-Null
			$result = Invoke-Git "submodule update --init --recursive"
			"[SFDXGitUpdateFolder.2.3] Results from updating submodules: $result" | Write-Host
		}
		
	}
	# The output for the SHA1 contains an extra ' 0', so we are removing it
	$result = Invoke-Git 'log -1 --format=format:"%H"'
    $currentSHA1 = ($result -split " ")[0]
	$result = Invoke-Git 'log -1 --format=format:"%s"' 
    $currentComment = $result
	$result = Invoke-Git 'log -1 --format=format:"%ae"' 
    $currentEmail = ($result -split " ")[0]
	$param.email = $currentEmail
	"[SFDXGitUpdateFolder.3.1] Current commit SHA1: $currentSHA1" | Write-Host
	"[SFDXGitUpdateFolder.3.2] Current commit comment: $currentComment" | Write-Host
	"[SFDXGitUpdateFolder.3.3] Current commit author email: $currentEmail" | Write-Host
    $currentSHA1
	return
}

# Parses the output from the package creation. Generates a HTML email and saves it as an Octopus variable
# Returns an int which is the result of the package creation run 
Function SFDXCreatePackage_GenerateEmail ($packageName, $branch, $version, $output)
{
	if (-Not ($output))
	{
		"[SFDXCreatePackage_GenerateEmail] ERROR - output from package creation is empty!" | Write-Output
		return 2
	}
	$jsonOutput = SFDXParseOutputAsJson $output
	"Result: $($jsonOutput.result)" | Write-Host
	"Message: $($jsonOutput.message)" | Write-Host
	"Errors:" | Write-Host
	$jsonOutput.result.Error | % { 
		$_ | Write-Host
	}
	"=== END JSONOUTPUT" | Write-Host
	
	$successStatus = ""
	$details = ""
	$NL = [System.Environment]::NewLine
	$parameterInformation = "        <p><h2><b>Parameters</b></h2></p><ul>" + $NL
	$parameterInformation = $parameterInformation + "            <li><b>Package short name: </b>$packageName</li>" + $NL
	$parameterInformation = $parameterInformation + "            <li><b>Branch: </b>$branch</li>" + $NL
	$parameterInformation = $parameterInformation + "            <li><b>Version: </b>$version</li></ul>" + $NL
	
	# If everything OK
	if ($jsonOutput.status -eq 0)
	{
		$successStatus = "succeeded"
		$details = $details + "        <p><h2><b>Package creation details</b></h2></p><ul>" + $NL
		$details = $details + "            <li><b>Id: </b>$($jsonOutput.result.Id)</li>" + $NL
		$details = $details + "            <li><b>Package2Id: </b>$($jsonOutput.result.Package2Id)</li>" + $NL
		$details = $details + "            <li><b>Package2VersionId: </b>$($jsonOutput.result.Package2VersionId)</li>" + $NL
		$details = $details + "            <li><b>SubscriberPackageVersionId: </b>$($jsonOutput.result.SubscriberPackageVersionId)</li>" + $NL
		$details = $details + "            <li><b>Tag: </b>$($jsonOutput.result.Tag)</li>" + $NL
		$details = $details + "            <li><b>Branch: </b>$($jsonOutput.result.Branch)</li>" + $NL
		$details = $details + "            <li><b>Created date: </b>$($jsonOutput.result.CreatedDate)</li></ul>" + $NL
	}
	else
	{
		$successStatus = "failed"
		$details = $details + "        <p><h2><b>Package creation error messages<b></h2></p><ul>" + $NL
		$details = $details + "            <li>$($jsonOutput.message)</li>" + $NL
	}
	
	$headerLine = "Salesforce DX package creation for $packageName $successStatus"
	$HTMLemail = "<html>" + $NL
	$HTMLemail = $HTMLemail + "    <body>" + $NL
	$HTMLemail = $HTMLemail + "        <h1>$headerLine</h1>" + $NL
	$HTMLemail = $HTMLemail + $parameterInformation
	$HTMLemail = $HTMLemail + $details
	$HTMLemail = $HTMLemail + "    </body>" + $NL
	$HTMLemail = $HTMLemail + "</html>"
	# Save this variable in Octopus 
	Set-OctopusVariable -name "emailSubject" -value $headerLine
	Set-OctopusVariable -name "emailBody" -value $HTMLemail
	
	return $jsonOutput.status
}


# Generates a new SFDX package
# packageName: The short name (sales, surveys) of the package which is generated.
# version: The new version that the new package will have. 
#   'latest' will retrieve the last version and add +0.0.0.1 to it
# commitSHA1: The commitSHA1 (usually branch name) from which the package will be created
Function SFDXGeneratePackage ($packageName, $version, $commitSHA1, $branch, $SFDXFolderName)
{
	"[SFDXGeneratePackage.0] Generating package: $packageName Version: $version Commit SHA1: $commitSHA1" | Write-Host
	# sfdx force:package:version:create -a "ver 1.0.1.2" -n 1.0.1.2 -d core/ -p salesforce-global-core -t 908254c -c -v sagegroup -w 5 -x
	$packageCompleteName = "salesforce-global-$packageName"
	# Cast to string if this is a number somehow
	$commitSHA1 = "$commitSHA1"
	# Use first 8 characters for the commit SHA1 (this is what the current packages use)
	$shortCommitSHA1 = $commitSHA1.substring(0, 7)
	$commandToRun = "sfdx force:package:version:create --versionname ""ver $version"" --versionnumber $version --path $packageName\ "
	$commandToRun = $commandToRun + "--package $packageCompleteName --tag $shortCommitSHA1 --branch $branch --codecoverage --targetdevhubusername $SFDXDevHubAlias "
	$commandToRun = $commandToRun + "--wait 10 --installationkeybypass --definitionfile config\scratch-org-config\project-scratch-def.json --json"
	
	"[SFDXGeneratePackage.1] command: $commandToRun" | Write-Host
	$currentFolder = Get-Location
	"[SFDXGeneratePackage.1] folder: $currentFolder" | Write-Host
	$output = (& cmd /c "$commandToRun" )
	return $output
}

# This function will be temporarily used to check if the user-entered input is in 1.2.3.4 format
Function SFDXValidatePackageVersionFormat ($version)
{
	$regex = "\d+\.\d+\.\d+\.\d+$"
	return ($version -match $regex)
}

# Retrieve latest version from dev hub
Function SFDXRetrieveLastPackageVersion ($packageName)
{	
	$param = @{"STEP_NUMBER"="1"; "DEBUG"="false"; "HTMLOutput"=""; "ExitStatus"=""}
	$PackageNames = @()
	$packageInfo = @{ "name" = "$packageName"; 		"packageName" = "salesforce-global-$packageName"; 		"isPackage" = $True;	"targetVersion" = "latest"}
	$PackageNames += $packageInfo
	$output = SFDXRetrievePackageIds $PackageNames $param
	if (-Not ($output.$packageName.version))
	{
		return ""
	}
	else
	{
		return $output.$packageName.version
	}
}

# Increment package version by 0.0.0.1
Function SFDXIncrementPackageVersion ($latestPackageVersion)
{
	$regex = "\d+\.\d+\.\d+\.\d+$"
	if ($latestPackageVersion -match $regex)
	{
		$versionParts = ($matches[0] -split "\.")
		$newReleaseNumber = [int]$versionParts[3] + 1
		$newVersion = $versionParts[0] + "." + $versionParts[1] + "." + $versionParts[2] + "." + $newReleaseNumber
		return $newVersion
	}
	else
	{
		return ""
	}
}

# Creates the package from the specified parameters
# packageName: The colloquial name for the package 'sales', 'core', 'config'
# branch: The branch from which the package is going to be created
Function SFDXCreatePackage ($packageName, $branch, $version, $param)
{
	"[SFDXCreatePackage] PARAMETERS:" | Write-Host
	"[SFDXCreatePackage] packageName: $packageName" | Write-Host
	"[SFDXCreatePackage] branch: $branch" | Write-Host
	"[SFDXCreatePackage] version: $version" | Write-Host
	
	$versionToUse = $version
	if ($version -eq "latest")
	{
		$latestPackageVersion = SFDXRetrieveLastPackageVersion $packageName
		if (-Not ($latestPackageVersion))
		{
			"[SFDXCreatePackage] WARNING - Unable to retrieve latest package version for $packageName ! Defaulting to 1.0.1.0 ..." | Write-Host
			$latestPackageVersion = "1.0.1.0"
		}
		$versionToUse = SFDXIncrementPackageVersion $latestPackageVersion
	}
	if (-Not ($versionToUse))
	{
		"[SFDXCreatePackage] ERROR - Unable to create package! $latestPackageVersion was not in the expected format (1.2.3.4)" | Write-Host
		Exit 2
	}
	$currentSHA1 = SFDXGitUpdateFolder -SFDXFolderName $packageName -branch $branch -fetchSubmodules $True -param $param
	$output = SFDXGeneratePackage -packageName $packageName -version $versionToUse -commitSHA1 $currentSHA1 -branch $branch -SFDXFolderName $packageName
	$param.NewVersion = $versionToUse
	return $output
}

# Saves the parameters for the packages introduced in Octopus Deploy into a text file
# Text file contents:
# <packageName1>=<parameter1>,<packageName2>=<parameter2>,<packageName3>=<parameter3> ...
# sales=latest,surveys=,core=1.0.2.3,connect=
Function SFDXSaveParameters
{
    $concatenatedParameters = ""
    $sep = ""
	$tempDict = @{}
	SFDXGetValidPackageNames -param $tempDict
    $tempDict.ValidPackageNames | % {
        $thisPackageUppercase = $_.substring(0,1).ToUpper() + $_.substring(1) 
        $paramName = "PackageVersion$thisPackageUppercase"
        $currentParameter = Get-Variable -Name $paramName -ErrorAction Ignore
        if (-Not ($currentParameter)) {
            "[SFDXSaveParameters] Warning! Parameter named $paramName was not found!" | Write-Host
            return # return inside of ForEach-Object cmdlet ignores the current element (like continue)
        }
        "[SFDXSaveParameters] Adding $_ = $($currentParameter.Value)" | Write-Host
        $concatenatedParameters = $concatenatedParameters + $sep + "$_=$($currentParameter.Value)"
        $sep = ","
    }
    "[SFDXSaveParameters] Concatenated parameter list: $concatenatedParameters" | Write-Host
    $tempFile = New-TemporaryFile
    Set-Content -path $tempFile.FullName -value $concatenatedParameters
    "[SFDXSaveParameters] Contents from temporary file in $($tempFile.FullName) :" | Write-Host
    Get-Content -path $tempFile.FullName
    $releaseId = $OctopusParameters['Octopus.Release.Id']
	"[SFDXSaveParameters] Saving $releaseId-parameters-user.txt..." | Write-Host
    New-OctopusArtifact -Path $tempFile.FullName -Name "$releaseId-parameters-user.txt"
	"[SFDXSaveParameters] Debug mode: ($SFDXDryRun)" | Write-Host
}

# Copied from non-DX library. 
# Retrieves all artifacts from the specified release.
Function SFDXRetrieveArtifacts
{
	Param(
    	[Parameter(Mandatory=$True)]
		[string]$OctopusAPIKey,
        [Parameter(Mandatory=$True)]
		[string]$ServerURL,
        [Parameter(Mandatory=$True)]
		[string]$ReleaseId
	)
	
	$octopusHeader = @{ "X-Octopus-ApiKey" = $OctopusAPIKey }
    "[SFDXRetrieveArtifacts] Executing $ServerURL/Octopus/api/artifacts?skip=0&regarding=$ReleaseId..." | Write-Host
    $artifactList = Invoke-RestMethod "$ServerURL/Octopus/api/artifacts?skip=0&regarding=$ReleaseId" -Method Get -Headers $octopusHeader
    "[SFDXRetrieveArtifacts] Artifacts found: $($artifactList.TotalResults)" | Write-Host
	$toReturn = @()
	foreach ($artifact in $artifactList.Items)
	{
		$currentArtifact = @{}
		$currentArtifact.Filename = $artifact.Filename
		$currentArtifact.URL = $artifact.Links.Content
		$toReturn += $currentArtifact
	}
	return $toReturn
}

# Copied from non-DX library. 
# Downloads the specified artifact and optionally unzips it into a folder of your choice
Function SFDXDownloadAndExtractArtifact
{
	Param(
    	[Parameter(Mandatory=$True)]
		[string]$OctopusAPIKey,
        [Parameter(Mandatory=$True)]
		[string]$ServerURL,
        [Parameter(Mandatory=$True)]
		[string]$ArtifactURL,
        [Parameter(Mandatory=$True)]
		[string]$BasePath,
        [Parameter(Mandatory=$True)]
		[string]$FileName,
		# Folder which contains this artifact (if empty, artifact will not be unzipped)
		# If this has any value, that folder is deleted first.
        [Parameter(Mandatory=$False)]
        [AllowEmptyString()]
		[string]$ExtractFolder,
        [Parameter(Mandatory=$False)]
        [AllowEmptyString()]
        [string]$NameOfExtractedFolderToDelete
	)
	
	$octopusHeader = @{ "X-Octopus-ApiKey" = $OctopusAPIKey }
	$artifactContent = Invoke-RestMethod "$ServerURL/$ArtifactURL" -Method Get -Headers $octopusHeader -OutFile "$BasePath\$FileName"
	if ((!$ExtractFolder) -Or ($ExtractFolder -eq ""))
	{
		"[SFDXDownloadAndExtractArtifact] Extract folder is null!" | Write-Host
		return
	}
	Add-Type -assembly "System.IO.Compression.FileSystem"
	"[SFDXDownloadAndExtractArtifact] Removing $BasePath\$NameOfExtractedFolderToDelete ..." | Write-Host
	Remove-Item "$BasePath\$NameOfExtractedFolderToDelete" -Recurse -ErrorAction Ignore
    "[SFDXDownloadAndExtractArtifact] Extracting $BasePath\$FileName to $BasePath\$ExtractFolder..." | Write-Host
	[IO.Compression.ZipFile]::ExtractToDirectory("$BasePath\$FileName", "$BasePath\$ExtractFolder")
    "[SFDXDownloadAndExtractArtifact] Removing $BasePath\$FileName ..." | Write-Host
    Remove-Item "$BasePath\$FileName" -Force -ErrorAction Ignore # Cleanup
}

Function SFDXGetParameterValues ($param)
{
	$releaseId = $OctopusParameters['Octopus.Release.Id']
	$list = SFDXRetrieveArtifacts -OctopusAPIKey $OctopusAPIKey -ServerURL $OctopusServerURL -ReleaseId $releaseId
	# If two deployments ran in parallel they might have created two -parsed files at the same time. We only need one though, so we do the select-object
	$parametersFile = ($list | ? { $_.Filename -match "parameters-parsed.txt" } | Select-Object -First 1 )
	if (-Not ($parametersFile)) 
	{
		"[SFDXGetParameterValues] Couldn't find parameters-parsed.txt file. It might be that this file hasn't been created yet (this will happen on DEV)." | Write-Host
		"[SFDXGetParameterValues] Attempting to read from parameters-user.txt file..." | Write-Host
		# We should only have one -user.txt file, but just in case
		$parametersFile = ($list | ? { $_.Filename -match "parameters-user.txt" } | Select-Object -First 1 )
		if (-Not ($parametersFile)) 
		{
			"[SFDXGetParameterValues] ERROR! Couldn't find parameters-user.txt file!" | Write-Host
			$param.ExitStatus = 81
			return
		}
	}
	$temporaryFolderLocation = [System.IO.Path]::GetTempPath()
	[string] $temporaryFileName = [System.Guid]::NewGuid()
	SFDXDownloadAndExtractArtifact -OctopusAPIKey $OctopusAPIKey -ServerURL $OctopusServerURL `
		-ArtifactURL $parametersFile.URL -BasePath $temporaryFolderLocation -FileName $temporaryFileName
	"[SFDXGetParameterValues] Contents from temporary file in temp path $temporaryFolderLocation\$temporaryFileName :" | Write-Host
	$fileContents = (Get-Content -Path "$temporaryFolderLocation\$temporaryFileName")
	$fileContents | Write-Host
	$toReturn = @{}
	# Each keypair value is separated by a comma
	($fileContents -split ",") | % {
		# The key pair itself is sp
		$currentKeyPair = ($_ -split "=")
		"[SFDXGetParameterValues] Adding $($currentKeyPair[0]) = $($currentKeyPair[1]) to parameter list..." | Write-Host
		$toReturn."$($currentKeyPair[0])" = "$($currentKeyPair[1])"
	}
	$param.parameters = $toReturn
}

# Function that will deploy the Admin package (from source)
# This could be extended to deploy all the packages that are to be deployed from source
Function SFDXRunDeploymentSource
{
	$param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $False }
	SFDXGetParameterValues -param $param
}

# Functions that support package promotion. These are modified from the above functions so there may be some further cleanup required in wording or code
Function SFDXPlanPromotion ($param, $allPackages)
{
	# allPackages is an array of package:
	# name = "Core", packageName = "salesforce-global-core", deploymentType = none|latest|semver|branch, targetVersion = (branch|packageVer)
	# Fields: BuildNumber (M.m.p.BN), Dependencies [array], Description, IsBeta, IsDeprecated, MajorVersion, MinorVersion, Name, PatchVersion, ReleaseState, SubscriberPackageId
	
	# 1. Set packageIds in allPackages dictionary
	SFDXPlanDeployment_SetAllPackageIds -allPackages $allPackages -param $param
	$environmentName = $OctopusParameters["Octopus.Environment.Name"]
	# The user inputs the parameters in the DEV environment only. For higher environments they are supposed to be read from the .txt file artifact
	# However, the user may have entered 'latest' as the requested package version, so we must replace it with the actual latest version
	# If we don't do this, then every time a deployment is promoted, it will pick up the latest package version and thus
	# the deployment won't be truly immutable
	SFDXPlanDeployment_RewriteParameters -allPackages $allPackages -param $param
	if ($param.ExitStatus -ne 0)
	{
		return
	}
	# At this point in time, $allPackages array contains these values, for each element:
	# "name"="Sales"; "packageName"="salesforce-global-sales"; "deploymentType"="semver"; "targetVersion" = "1.0.1.8"; "packageId" = "04t1o000000Y6OtAAK"
	# 2. Create the actual package list with ordering
	$packageList = SFDXPlanDeployment_PromotionPackageList -allPackages $allPackages -param $param
	# 3. Validate the package list to see if there are mismatched versions
	SFDXPlanDeployment_ValidatePackageList -packageList $packageList -param $param
	SFDXPlanDeployment_OutputPackageList -packageList $packageList
	$param.packageList = $packageList
}

Function SFDXPlanDeployment_PromotionPackageList ($allPackages, $param)
{
	$packageList = @{}
	$devhubPackagesList = $param.DevhubPackagesList
	$allPackages | % {
		# These first sentences print the state of the package list to debug		
		"[SFDXPlanDeployment_PromotionPackageList.$($_.name)] Package list -- START" | Write-Host
		$packageList.GetEnumerator() | % {
			"Key: $($_.Name) order: $($_.Value.order) requiredBy:" | Write-Host
			$_.Value.requiredBy | % { "    packageName: $($_.packageName) version: $($_.version) packageId: $($_.packageId) " | Write-Host }
		}
		"[SFDXPlanDeployment_PromotionPackageList.1.$($_.name)] Package list -- END" | Write-Host
		# First, attempt to add this package to the list
		$basePositionForElement = $packageList.Count
		$basePackageName = $_.packageName
		# packageRequiringThis = "user" because this is not a dependency; it is read from a parameter
		SFDXPlanDeployment_AddToPackageList -packageList $packageList -currentPackage $_ -preferredOrder $basePositionForElement -packageRequiringThis "user" -param $param

		"[SFDXPlanDeployment_PromotionPackageList.2.$($_.name)] Package list -- START" | Write-Host
		$packageList.GetEnumerator() | % {
			"Key: $($_.Name) order: $($_.Value.order) deploymentType: $($_.Value.deploymentType) packageName: $($_.Value.packageName) requiredBy:" | Write-Host
			$_.Value.requiredBy | % { "    packageName: $($_.packageName) version: $($_.version) packageId: $($_.packageId)" | Write-Host }
		}
		"[SFDXPlanDeployment_PromotionPackageList.$($_.name)] Package list -- END" | Write-Host
		if ($_.deploymentType -eq "branch") { 
			# NOTE: If we ever have some repositories where we want to deploy from source AND we want some packages to be installed first as dependencies 
			# we would need to modify a good part of this function. Right now, the dependency-checking script is doing a soql query 
			# to retrieve the dependencies that a *package* has. This is querying the devhub. 
			# If we wanted to have the same functionaliry for a source deployment then we would have to read
			# from the sfdx-project.json file, parse it and understand the package versions required for this package.
			# This would also mean checking out each of those repositories, on the branch that is to be deployed to read
			# the correct sfdx-project.json file.
			# We can't query the devhub for this information, because the package isn't created yet!
			"[SFDXPlanDeployment_PromotionPackageList.$($_.name)] Deployment type is set to source. Skipping dependency validations..." | Write-Host
			# return inside of ForEach-Object cmdlet ignores the current element (like continue)
			return 
		} 
	}
	return $packageList
}

#Testing package promotion
Function SFDXRunPromotePackage
{
    # ExitStatus
    # 0: Success
    # 10: Error validating parameters
    # 20: Error retrieving package IDs
    # 21: Error matching desired package version to actual versions
    # 40: Error installing unlocked package
    # 51: Error deploying sales/common source
    # 52: Error deploying sales source
    # 60: Test run failed
	
    $param = @{ "ExitStatus" = 0; "HTMLOutput" = ""; "STEP_NUMBER" = 1; "DEBUG" = $False }
	SFDXGetParameterValues -param $param
	SFDXConfigurePackageInformation -param $param
	$allPackages = $param.allPackages
	# On here, I should get the packages that have either a package version or 'latest'
	# from there I must reconstruct the actual package versions that need deployment
	# Later I will check and not install a package if it's already there on the sandbox
	"[SFDXRunPromotePackage] List of actual packages to promote -- START" | Write-Host
	$packagesToPromote = @()
	$allPackages | % {
		if (($_.deploymentType -eq "semver") -Or ($_.deploymentType -eq "latest")) {
			$packagesToPromote += $_
		"    Package: $($_.packageName) Version: $($_.targetVersion)" | Write-Host
		}
		#elseif ($_.deploymentType -eq "branch") {
		#	$packagesToPromote += $_
		#"    Repository: $($_.packageName) Source branch: $($_.targetVersion)" | Write-Host
		#}
		
	}
	"[SFDXRunPromotePackage] List of actual packages to promote -- END" | Write-Host
	SFDXGetValidPackageData -param $param
	SFDXAuthenticateEnvironment -alias $SFDXSandboxAlias -token $SFDXAuthDeploymentURL -param $param
	SFDXPlanPromotion -param $param -allPackages $packagesToPromote
	if ($param.ExitStatus -ne 0)
	{
		SFDXSaveHTMLOutputForNextStep -param $param
		"[SFDXRunPromotePackage] Error validating packages! ExitStatus: $($param.ExitStatus)"  | Write-Error
		Exit $param.ExitStatus
	}

	SFDXPromotePackage -packageList $param.packageList -OrgAlias $SFDXSandboxAlias -param $param
	if ($param.ExitStatus -ne 0)
	{
		SFDXSaveHTMLOutputForNextStep -param $param
		if ($param.ExitStatus -eq 71)
		{
			"[SFDXRunPromotePackage] Package version validation failed!"  | Write-Host
		}
		"[SFDXRunPromotePackage] Error installing packages! ExitStatus: $($param.ExitStatus)"  | Write-Error
		Exit $param.ExitStatus
	}
	$packageIds = @()
	$param.packageList.GetEnumerator() | ? { $_.Value.deploymentType -eq "package"} | % {
		$packageIds += $_.Value.deployPackageId 
	}

	SFDXSaveHTMLOutputForNextStep -param $param
}

Function SFDXPromotePackage ($packageList, $OrgAlias, $param)
{
	$atLeastOnePackageInstalled = $False
	$packageList.GetEnumerator() | Sort-Object { $_.Value.order } | % {
		if ($_.Value.alreadyInstalled) {
			"[SFDXPromotePackage.$($_.Value.order)] Package with ID: $($_.Value.deployPackageId) already installed! Skipping installation..." | Write-Host
			return # return acts as continue in Foreach-Object loop
		}
		$shortPackageName = ($_.Key -replace "salesforce-global-", "")
		if ($_.Value.deploymentType -eq "package") {
			"[SFDXPromotePackage.$($_.Value.order)] Package with ID: $($_.Value.deployPackageId) is being promoted..." | Write-Host
			SFDXPackagePromotion -PackageId $_.Value.deployPackageId -PackageName $_.Key -IsLastPackage $False -param $param -dryrun $SFDXDryRun
			# If package installation failed, we shouldn't continue
			if ($param.ExitStatus -ne 0) {
				SFDXSaveHTMLOutputForNextStep -param $param
				"[SFDXPromotePackage] Error promoting package $shortPackageName! ExitStatus: $($param.ExitStatus)"  | Write-Error
				Exit $param.ExitStatus
			}
		}
		$atLeastOnePackageInstalled = $True
	}
	# As we don't know which package is the last package, we add this manually.
	if ($atLeastOnePackageInstalled)
	{
		$param.HTMLOutput = $param.HTMLOutput + "        </ul>" + $NL
	}
}

Function SFDXPackagePromotion ($OrgAlias, $PackageId, $PackageName, $IsLastPackage = $False, $param, $dryrun = $False)
{
	$SN = $param.STEP_NUMBER
	"    [$SN][SFDXPackagePromotion.1] Promoting package with ID $PackageId to org: $SFDXDevHubAlias" | Write-Host
	$commandToRun = "sfdx force:package:version:promote --package ""$PackageId"" --targetdevhubusername ""$SFDXDevHubAlias"" --noprompt --json"
	if ($dryrun -eq "true") {
		"[SFDXPackagePromotion] DRY RUN --- Command that would be run:" | Write-Host
		"    sfdx force:package:version:promote --package ""$PackageId"" --targetdevhubusername ""$SFDXDevHubAlias"" --noprompt --json" | Write-Host
		return
	}
	"[$SN][SFDXPackagePromotion.2] Command to run: $commandToRun" | Write-Host
	$output = SFDXRunCommandCapturingOutputError -CommandToRun $commandToRun
	if ($param.DEBUG) { "    [$SN][SFDXPackagePromotion.3] LASTEXITCODE: $LASTEXITCODE..." | Write-Host }
	if ($param.DEBUG) { 
		"    [$SN][SFDXPackagePromotion.3.2] Installation output -- START" | Write-Host
		$output.Output | Write-Host
		"    [$SN][SFDXPackagePromotion.3.2] Installation output -- END" | Write-Host 
	}
	
	SFDXParseInstallationOutput -Output $output.Output -PackageId $PackageId -PackageName $PackageName -IsLastPackage $IsLastPackage -param $param
}

# SFDX Functions -- END
