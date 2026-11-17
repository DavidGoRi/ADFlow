# Laboratorio de pruebas: un controlador de dominio en Hyper-V

*Read in [English](LAB.md).*

Esta guía monta un dominio de pruebas gratuito y aislado (`corp.example.com`) en
una máquina virtual de Hyper-V y ejecuta ADFlow contra él con
`-Provider ActiveDirectory`. Nada de esto toca un dominio real: el script del
laboratorio se niega a ejecutarse en un dominio distinto al de los datos de
ejemplo.

Tiempo: alrededor de una hora, casi toda esperando instalaciones.

## 1. Qué hace falta

- Windows 10/11 **Pro, Enterprise o Education** (Hyper-V no está en Home), con
  la virtualización activada en la BIOS/UEFI.
- 8 GB de RAM como mínimo (con 16 GB se va holgado) y 60 GB libres en disco.
- Windows Server Evaluation: gratis durante 180 días y sin clave de producto.

## 2. Activar Hyper-V

En PowerShell **como administrador** y después reiniciar:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

## 3. Descargar Windows Server Evaluation

Descarga la ISO de **Windows Server 2025** (o 2022) desde el
[Centro de evaluación de Microsoft](https://www.microsoft.com/evalcenter).
Microsoft pide rellenar un formulario corto. La ISO en inglés es la más fácil
de seguir con esta guía, porque los nombres de las opciones coinciden.

## 4. Crear la máquina virtual

Como administrador, con la ruta de tu ISO:

```powershell
$iso = 'C:\ISO\WindowsServer2025_Eval.iso'
New-VM -Name DC01 -Generation 2 -MemoryStartupBytes 4GB -SwitchName 'Default Switch' `
    -NewVHDPath "$env:PUBLIC\Documents\Hyper-V\DC01.vhdx" -NewVHDSizeBytes 60GB
Set-VMProcessor -VMName DC01 -Count 2
Add-VMDvdDrive -VMName DC01 -Path $iso
Set-VMFirmware -VMName DC01 -FirstBootDevice (Get-VMDvdDrive -VMName DC01)
Start-VM -Name DC01
vmconnect.exe localhost DC01
```

Pulsa una tecla cuando la máquina muestre *Press any key to boot from CD or
DVD*. Elige **Windows Server … Standard Evaluation (Desktop Experience)**, una
instalación personalizada en el disco vacío, y pon la contraseña del
administrador.

El *Default Switch* da a la máquina acceso a internet mediante NAT, y para el
laboratorio basta. Su dirección IP puede cambiar al reiniciar el equipo
anfitrión; en un laboratorio no importa.

## 5. Convertir el servidor en controlador de dominio

Dentro de la máquina, en PowerShell como administrador:

```powershell
Rename-Computer -NewName DC01 -Restart
```

Después del reinicio:

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName corp.example.com -DomainNetbiosName CORP -InstallDns
```

Pide una contraseña de *modo seguro* (DSRM) y reinicia. Vuelve a entrar como
`CORP\Administrator`.

`example.com` está reservado para documentación (RFC 2606), así que este dominio
nunca puede chocar con uno real.

**Haz un punto de control ahora**, para poder volver siempre a un dominio limpio:

```powershell
# En el equipo anfitrión
Checkpoint-VM -Name DC01 -SnapshotName 'Clean domain'
```

## 6. Llevar ADFlow a la máquina

La máquina tiene internet por el Default Switch:

```powershell
Invoke-WebRequest https://github.com/DavidGoRi/ADFlow/archive/refs/heads/main.zip -OutFile $env:TEMP\adflow.zip
Expand-Archive $env:TEMP\adflow.zip -DestinationPath C:\
Get-ChildItem C:\ADFlow-main -Recurse | Unblock-File
Set-Location C:\ADFlow-main
```

## 7. Cargar los datos de ejemplo

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\New-ADFlowLab.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\tools\New-ADFlowLab.ps1
```

Crea las OU de `demo/directory.json` (primero las de arriba), los grupos en
`OU=Groups`, los usuarios de ejemplo con contraseñas aleatorias que nadie
conoce, y los recursos compartidos `\\DC01\home$` y `\\DC01\archive$` en
`C:\Shares`. Se puede volver a ejecutar cuando quieras: solo crea lo que falta.

Abre **Usuarios y equipos de Active Directory** (`dsa.msc`) para ver el
resultado.

## 8. Ejecutar ADFlow contra el dominio

Empieza siempre con una simulación:

```powershell
$ad = @{ Provider = 'ActiveDirectory'; HomeRoot = '\\DC01\home$'; ArchiveRoot = '\\DC01\archive$' }

.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv @ad -DryRun
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv @ad
```

Comprueba en `dsa.msc` que las cuentas están en sus OU y grupos, y mira los
permisos de una carpeta personal:

```powershell
(Get-Acl \\DC01\home$\jose.pena).Access | Format-Table IdentityReference, FileSystemRights, IsInherited
```

Después las bajas y la reversión (el identificador de la ejecución lo muestra la
orden anterior):

```powershell
.\ADFlow.ps1 -Action Offboard -CsvPath .\demo\leavers.csv @ad
.\ADFlow.ps1 -Action Undo -RunId <identificador> @ad
```

Cada ejecución deja `report.html` y la auditoría en `output\runs\<identificador>\`.

Para ejecutar ADFlow desde tu propio equipo en vez de desde el controlador, el
equipo tiene que estar unido al dominio del laboratorio y tener RSAT:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv @ad -Server DC01.corp.example.com -Credential (Get-Credential)
```

## 9. Volver a empezar o borrarlo todo

```powershell
# En el equipo anfitrión: volver al dominio limpio
Restore-VMCheckpoint -VMName DC01 -Name 'Clean domain' -Confirm:$false

# O borrar el laboratorio entero
Stop-VM -Name DC01 -TurnOff
Remove-VM -Name DC01 -Force
Remove-Item "$env:PUBLIC\Documents\Hyper-V\DC01.vhdx"
```

La evaluación caduca a los 180 días; rehacer el laboratorio con esta guía lleva
alrededor de una hora.

## Qué cubren los tests y qué solo se ve en el laboratorio

Los tests de GitHub Actions ejecutan el proveedor de Active Directory contra un
módulo ActiveDirectory simulado (`tests/FakeActiveDirectory.psm1`) y pasan los
mismos tests de contrato a los dos proveedores. Así se comprueban la lógica, los
filtros LDAP y los parámetros que ADFlow pasa a cada cmdlet. El resto solo se ve
con un dominio real: los permisos de la cuenta que ejecuta ADFlow, los retrasos
de replicación entre controladores, las directivas de contraseñas y cómo aplica
el servidor de archivos los permisos de las carpetas. Para eso sirve este
laboratorio.
