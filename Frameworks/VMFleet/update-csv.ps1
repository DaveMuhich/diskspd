<#
DISKSPD - VM Fleet

Copyright(c) Microsoft Corporation
All rights reserved.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

param(
    $disableintegrity = $false,
    $renamecsvmounts = $false,
    $movecsv = $true,
    $movevm = $true,
    $shiftcsv = $false
)

$csv = get-clustersharedvolume

if ($disableintegrity) {
    $csv |% {
        dir -r $_.SharedVolumeInfo.FriendlyVolumeName | Set-FileIntegrity -Enable:$false -ErrorAction SilentlyContinue
    }
}

if ($renamecsvmounts) {
    $csv |% {
        if ($_.SharedVolumeInfo.FriendlyVolumeName -match 'Volume\d+$') {
            if ($_.name -match '\((.*)\)') {
                ren $_.SharedVolumeInfo.FriendlyVolumeName $matches[1]
            }
        }
    }
}

function move-csv(
    $rehome = $true,
    $shift = $false
    )
{
    if ($shift) {

        write-host -fore Yellow Shifting CSV owners

        # rotation order (n0 -> n1, n1 -> n2, ... nn -> n0)
        $nodes = (Get-ClusterNode |? State -eq Up | sort -Property Name).Name
        $nh = @{}
        foreach ($i in 1..($nodes.Length-1)) {
            $nh[$nodes[$i-1]] = $nodes[$i]
        }
        $nh[$nodes[$nodes.Length-1]] = $nodes[0]

        $csv = Get-ClusterSharedVolume
        Get-ClusterNode |% {
            $csv |? Name -match "\($($_.Name)" |% {
                $_ | Move-ClusterSharedVolume $nh[$_.OwnerNode.Name]
            }
        }

    } elseif ($rehome) {

        # write-host -fore Yellow Re-homing CSVs

        # move all csvs named by node names back to their named node
        get-clusternode |? State -eq Up |% {
            $node = $_.Name
            $csv |? Name -match "\($node" |? OwnerNode -ne $node |% { $_ | move-clustersharedvolume $node }
        }
    }
}

if ($shiftcsv) {
    # shift rotates all csvs node ownership by one node, in lexical order of
    # current node owner name. this is useful for forcing out-of-position ops.
    move-csv -shift:$true
} elseif ($movecsv) {
    # move puts all csvs back on their home node
    move-csv -rehome:$true
}

if ($movevm) {

    icm (get-clusternode |? State -eq Up) {

        get-clustergroup |? GroupType -eq VirtualMachine |% {

            if ($_.Name -like "vm-*-$env:COMPUTERNAME-*") {
                if ($env:COMPUTERNAME -ne $_.OwnerNode) {
                    write-host -ForegroundColor yellow moving $_.name $_.OwnerNode '->' $env:COMPUTERNAME

                    # the default move type is live, but live does not degenerately handle offline vms yet
                    if ($_.State -eq 'Offline') {
                        Move-ClusterVirtualMachineRole -Name $_.Name -Node $env:COMPUTERNAME -MigrationType Quick
                    } else {
                        Move-ClusterVirtualMachineRole -Name $_.Name -Node $env:COMPUTERNAME
                    }
                } else {
                    # write-host -ForegroundColor green $_.name is on $_.OwnerNode
                }
            }
        }
    }
}
