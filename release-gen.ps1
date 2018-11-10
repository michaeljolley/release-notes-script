#
# Assumptions
#
# 1. If you have a Octopus release deployed, say 1.0.0.73, there is a git
#    tag set for that commit in GitHub that is "1.0.0.73".
#
# 2. The latest production deployment will be used for comparison, even
#    if the deployment failed.
#
# 3. Your default branch is "master".
#


#
# Define all necessary variables
# ---------------------------------------------------------
$global:github_owner = "GitHub Owner Name Here"
$global:github_repo = "GitHub Repo Name Here"
$global:github_token = "GitHub Personal Access Token"

$global:octopus_url = 'Url to Octopus Deploy'
$global:octopus_username = "Octopus Deploy Username"
$global:octopus_password = ConvertTo-SecureString "Octopus Deploy Password" -AsPlainText -Force
$global:octopus_apikey = "Octopus Deploy API Key"
$global:octopus_projectName = "Octopus Deploy Project Name"
$global:octopus_productionEnvironment = "Name of Production Environment in Octopus Deploy"

$global:current_commitId = $env:APPVEYOR_REPO_COMMIT

$issue_closing_pattern = new-object System.Text.RegularExpressions.Regex('([Cc]loses|[Ff]ixes) +#\d+',[System.Text.RegularExpressions.RegexOptions]::Singleline)

#
# GitHub API
# ---------------------------------------------------------
$github = New-Module -ScriptBlock {
    function GetCommits {
        param([string] $base, [string] $head)
		$url = "https://api.github.com/repos/$github_owner/$github_repo/compare/" + $base + "..." + $head + "?access_token=$github_token"
        return  Invoke-RestMethod -Uri $url -Verbose
    }
 
    Export-ModuleMember -Function GetCommits
} -AsCustomObject
 
#
# Octopus API
# ---------------------------------------------------------
$octo = New-Module -ScriptBlock {
    $password = $octopus_password
    $credentials = New-Object System.Management.Automation.PSCredential ("$octopus_username", $octopus_password)

    function Get {
        param([string] $url)
        return Invoke-RestMethod -Uri $octopus_url$url -ContentType application/json -Headers @{"X-Octopus-ApiKey"="$octopus_apikey"} -Method Get -Credential $credentials -Verbose
    }
 
    function GetProject {
        param([string] $name)
        $projects = $root.Links.Projects
        $project_url = "$projects".Replace("{/id}{?name,skip,ids,clone,take,partialName}", "")
        $projects = Get($project_url)
        
        foreach ($project in $projects.Items) {
            if ([string]::Compare($project.Name, $name, $true) -eq 0) {
                return $project;
            }
        }
 
        throw "A project named '$name' could not be found."
    }
    
    function GetEnvironment {
        
    }
 
    function GetLatestDeployedRelease {
        param($project)
        
        # Get the production environment
        $environment_url = $root.Links.Environments.Replace("{/id}{?name,skip,ids,take,partialName}", "")
        $environments = Get($environment_url) 
        
        foreach ($env in $environments.Items) {
          if ([string]::Compare($env.Name, $octopus_productionEnvironment, $true) -eq 0) {
          
            $deployments_url = $root.Links.Deployments.Replace("{/id}{?skip,take,ids,projects,environments,tenants,channels,taskState,partialName}", "") + "?environments=" + $env.Id + "&take=1"
            
            $deployment = Get($deployments_url)
            
            $release_url = $deployment.Items[0].Links.Release
            
            return Get($release_url)
            
          }
        }
        
        throw "An environment named '$octopus_productionEnvironment' could not be found."
       
    }
 
    Export-ModuleMember -Function GetProject, GetLatestDeployedRelease
 
    $root = Get("/api")
} -AsCustomObject
 
#
# Get all commits from latest deployment to this commit
# ---------------------------------------------------------

$project = $octo.GetProject($octopus_projectName)
$release = $octo.GetLatestDeployedRelease($project)
Write-Host ("Getting all commits from git tag v" + $release.Version + " to commit sha $current_commitId.")

$response = $github.GetCommits($release.Version, $current_commitId)

$commits = $response.commits | Sort-Object -Property @{Expression={$_.commit.author.date}; Ascending=$false} -Descending

#
# Generate release notes based on commits and issues
# ---------------------------------------------------------
Write-Host "Generating release notes based on commits."
$nl = [Environment]::NewLine
$HTMLreleaseNotes = "<h2>Release Notes</h2>$nl" +
"<h5>Version <a href='https://github.com/$github_owner/$github_repo/tree/" + $env:build_version + "' target='_blank'>" + $env:build_version + "</a></h5>$nl"

$releaseNotes = "## Release Notes<br/>$nl" +
"#### Version [" + $env:build_version + "](https://github.com/$github_owner/$github_repo/tree/" + $env:build_version + ")$nl"

if ($commits -ne $null) {

	$HTMLreleaseNotes = $HTMLreleaseNotes + "<table><thead><tr><th style='width:140px'>Commit</th><th>Description</th></tr></thead><tbody>$nl"

	$releaseNotes = $releaseNotes + "Commit | Description<br/>$nl" + "------- | -------$nl"

	foreach ($commit in $commits) {
		
		$commitMessage = $commit.commit.message.Replace("`r`n"," ").Replace("`n"," ");
		$m = $issue_closing_pattern.Matches($commitMessage)

		foreach($match in $m) {
					$issueNumber = [regex]::Replace($match, "([Cc]loses|[Ff]ixes) +#", "");
					$matchLink = "<a href='https://github.com/$github_owner/$github_repo/issues/$issueNumber' target='_blank'>$match</a>";
					$commitMessage = [regex]::Replace($commitMessage, $match, $matchLink);
		}

		if (-Not $commit.commit.message.ToLower().StartsWith("merge") -and
			-Not $commit.commit.message.ToLower().StartsWith("merging") -and
			-Not $commit.commit.message.ToLower().StartsWith("private")) {
		  
			$HTMLreleaseNotes = $HTMLreleaseNotes + "<tr><td style='width:140px'><a href='https://github.com/$github_owner/$github_repo/commit/" + $commit.sha + "' target='_blank'>" + $commit.sha.Substring(0, 10) + "</a></td><td>" + $commitMessage + "</td></tr>$nl"
			$releaseNotes = $releaseNotes + "[" + $commit.sha.Substring(0, 10) + "](https://github.com/$github_owner/$github_repo/commit/" + $commit.sha + ") | " + $commit.commit.message.Replace("`r`n"," ").Replace("`n"," ") + "$nl"
		}

		
		if ($commit.commit.message.ToLower().StartsWith("private")) {
			$releaseNotes = $releaseNotes + "[" + $commit.sha.Substring(0, 10) + "](https://github.com/$github_owner/$github_repo/commit/" + $commit.sha + ") | " + $commit.commit.message.Replace("`r`n"," ").Replace("`n"," ") + "$nl"
		}

	}
 
	$HTMLreleaseNotes = $HTMLreleaseNotes + "</tbody></table>$nl"
}
else {
    $releaseNotes = $releaseNotes + "There are no new items for this release.$nl"
}

New-Item releasenotes.txt -type file -force -value $releaseNotes
New-Item htmlreleasenotes.txt -type file -force -value $HTMLreleaseNotes

$env:octo_releasenotes = $releaseNotes.Replace($nl, '\n')
$env:octo_htmlreleasenotes = $HTMLreleaseNotes
