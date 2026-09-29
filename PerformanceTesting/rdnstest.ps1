$Gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" |
    Sort-Object RouteMetric |
    Select-Object -First 1).NextHop

try {
    $HostName = [System.Net.Dns]::GetHostEntry($Gateway).HostName
}
catch {
    $HostName = "<Unresolved>"
}

"$Gateway -> $HostName"