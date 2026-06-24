#Requires -Version 5.1
#Requires -Modules ActiveDirectory
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Provisionne l'Active Directory de MEDISOL (clinique bien-être / MSPR) :
    OU, groupes par métier, groupes de ressources et comptes utilisateurs.

.DESCRIPTION
    Données 100 % FICTIVES (projet d'école). Aucun compte réel.
    Script IDEMPOTENT : il peut être relancé sans créer de doublons.

    Modèle AGDLP (bonne pratique Microsoft) :
        Comptes  ->  Groupes Globaux (métier)  ->  Groupes Domaine Local (ressources)  ->  Permissions NTFS
    Les groupes "GG-*" regroupent les personnes par métier.
    Les groupes "DL-*" servent à poser les droits sur les partages du serveur de fichiers.

.NOTES
    À exécuter SUR le contrôleur de domaine (ou une machine avec RSAT-AD), en tant qu'administrateur.
    Adaptez la section CONFIGURATION ci-dessous, puis lancez :  .\Provision-MEDISOL-AD.ps1
#>

# =============================== CONFIGURATION ===============================
$Company         = 'MEDISOL'
$DefaultPwdPlain = 'Medisol@2026!'   # mot de passe initial (changé à la 1re connexion)
$ChangeAtLogon   = $true             # forcer le changement de mot de passe à la 1re ouverture
$UpnSuffix       = $null             # ex: 'medisol.local' ; laisser $null = suffixe du domaine courant
$ProtectOU       = $false            # $false en lab (relance/suppression faciles) ; $true en production
$CsvPath         = Join-Path $PSScriptRoot 'medisol-comptes.csv'  # récap exporté en fin de script
# =============================================================================

Import-Module ActiveDirectory -ErrorAction Stop

# Détection automatique du domaine
$domain   = Get-ADDomain
$DomainDN = $domain.DistinguishedName              # ex: DC=medisol,DC=local
if (-not $UpnSuffix) { $UpnSuffix = $domain.DNSRoot }
$SecurePwd = ConvertTo-SecureString $DefaultPwdPlain -AsPlainText -Force

$BaseOUPath  = "OU=$Company,$DomainDN"
$UsersOUPath = "OU=Utilisateurs,$BaseOUPath"
$GrpMetierOU = "OU=Groupes-Metiers,$BaseOUPath"
$GrpResOU    = "OU=Groupes-Ressources,$BaseOUPath"

$script:Report = New-Object System.Collections.Generic.List[object]

# ============================== FONCTIONS UTILES =============================
function Remove-Diacritics {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $norm = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Get-SamAccountName {
    param([string]$First, [string]$Last)
    $s = ('{0}.{1}' -f (Remove-Diacritics $First), (Remove-Diacritics $Last)).ToLower()
    $s = $s -replace '\s', '' -replace '[^a-z0-9.\-]', ''
    if ($s.Length -gt 20) { $s = $s.Substring(0, 20) }   # limite sAMAccountName (20 car.)
    return $s
}

function New-OUIfMissing {
    param([string]$Name, [string]$ParentPath)
    $exists = Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $ParentPath -SearchScope OneLevel -ErrorAction SilentlyContinue
    if (-not $exists) {
        New-ADOrganizationalUnit -Name $Name -Path $ParentPath -ProtectedFromAccidentalDeletion $ProtectOU | Out-Null
        Write-Host "OU créée            : OU=$Name,$ParentPath" -ForegroundColor Green
    } else {
        Write-Host "OU déjà présente    : OU=$Name,$ParentPath" -ForegroundColor DarkGray
    }
}

function New-GroupIfMissing {
    param(
        [string]$Name,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$Scope,
        [string]$Path,
        [string]$Description
    )
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Name -SamAccountName $Name -GroupScope $Scope -GroupCategory Security `
                    -Path $Path -Description $Description | Out-Null
        Write-Host "Groupe créé         : $Name ($Scope)" -ForegroundColor Green
    } else {
        Write-Host "Groupe déjà présent : $Name" -ForegroundColor DarkGray
    }
}

function Add-MemberIfMissing {
    param([string]$Group, [string]$MemberSam)
    $already = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue |
               Where-Object { $_.SamAccountName -eq $MemberSam }
    if (-not $already) { Add-ADGroupMember -Identity $Group -Members $MemberSam }
}

function New-UserIfMissing {
    param([string]$First, [string]$Last, [string]$Service, [string]$Title, [string]$OUPath, [string]$Group)
    $sam = Get-SamAccountName $First $Last
    $upn = "$sam@$UpnSuffix"
    $display = "$First $Last"

    if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
        $params = @{
            Name                  = $display
            GivenName             = $First
            Surname               = $Last
            SamAccountName        = $sam
            UserPrincipalName     = $upn
            DisplayName           = $display
            Path                  = $OUPath
            AccountPassword       = $SecurePwd
            Enabled               = $true
            ChangePasswordAtLogon = $ChangeAtLogon
            Company               = $Company
            Department            = $Service
            Title                 = $Title
        }
        New-ADUser @params | Out-Null
        Write-Host "  Utilisateur créé  : $display ($sam)" -ForegroundColor Green
    } else {
        Write-Host "  Utilisateur existe: $sam" -ForegroundColor DarkGray
    }

    Add-MemberIfMissing -Group $Group -MemberSam $sam
    $script:Report.Add([pscustomobject]@{
        Nom = $display; Identifiant = $sam; UPN = $upn; Service = $Service; Fonction = $Title; GroupeMetier = $Group
    })
}

# ============================ DONNÉES (FICTIVES) =============================
# Un bloc par service : OU dédiée, groupe métier (global), et la liste des personnes.
$Services = @(
    @{ OU='Direction';     Group='GG-Direction';     Desc='Direction et administration'; Users=@(
        @{First='Hélène';  Last='Marchand'; Title='Directrice'}
        @{First='Bruno';   Last='Vasseur';  Title='Responsable administratif'}
    )},
    @{ OU='Secretariat';   Group='GG-Secretariat';   Desc='Secrétariat et accueil'; Users=@(
        @{First='Camille'; Last='Robin';      Title='Secrétaire médicale'}
        @{First='Sofiane'; Last='Amrani';     Title='Secrétaire médical'}
        @{First='Laura';   Last='Petit';      Title="Assistante d'accueil"}
        @{First='Nadia';   Last='Lefèvre';    Title='Secrétaire médicale'}
        @{First='Thomas';  Last='Garnier';    Title="Agent d'accueil"}
        @{First='Inès';    Last='Carpentier'; Title='Secrétaire médicale'}
    )},
    @{ OU='Praticiens';    Group='GG-Praticiens';    Desc='Praticiens (médecine douce)'; Users=@(
        @{First='Hélène';  Last='Renaud';   Title='Ostéopathe'}
        @{First='Camille'; Last='Forster';  Title='Sophrologue'}
        @{First='Léa';     Last='Mansart';  Title='Diététicienne'}
        @{First='Julien';  Last='Bonnet';   Title='Ostéopathe'}
        @{First='Sarah';   Last='Lemoine';  Title='Naturopathe'}
        @{First='Antoine'; Last='Mercier';  Title='Kinésithérapeute'}
        @{First='Claire';  Last='Dubois';   Title='Psychologue'}
        @{First='Hugo';    Last='Faure';    Title='Acupuncteur'}
        @{First='Manon';   Last='Girard';   Title='Sophrologue'}
        @{First='Yanis';   Last='Benoit';   Title='Ostéopathe'}
    )},
    @{ OU='Imagerie';      Group='GG-Imagerie';      Desc='Imagerie légère'; Users=@(
        @{First='Marc';    Last='Aubris';    Title='Radiologue'}
        @{First='Pauline'; Last='Roy';       Title='Manipulatrice radio'}
        @{First='Karim';   Last='Haddad';    Title='Manipulateur radio'}
        @{First='Élodie';  Last='Chevalier'; Title='Manipulatrice radio'}
    )},
    @{ OU='Comptabilite';  Group='GG-Comptabilite';  Desc='Comptabilité et RH'; Users=@(
        @{First='Sandrine'; Last='Olivier'; Title='Comptable'}
        @{First='Patrick';  Last='Noel';    Title='Responsable RH'}
        @{First='Aurélie';  Last='Masson';  Title='Gestionnaire paie'}
    )},
    @{ OU='Informatique';  Group='GG-Informatique';  Desc='Informatique'; Users=@(
        @{First='David';   Last='Leroy';   Title='Administrateur systèmes'}
        @{First='Mehdi';   Last='Slimani'; Title='Technicien support'}
    )},
    @{ OU='Logistique';    Group='GG-Logistique';    Desc='Logistique et entretien'; Users=@(
        @{First='José';    Last='Pereira'; Title='Agent logistique'}
        @{First='Fatou';   Last='Diallo';  Title="Agent d'entretien"}
        @{First='Eric';    Last='Lambert'; Title='Responsable des locaux'}
    )}
)

# Groupes de RESSOURCES (Domaine Local) -> on y posera les permissions NTFS des partages.
$ResourceGroups = @(
    @{ Name='DL-Partage-Direction-RW';    Desc='Partage Direction - lecture/écriture' }
    @{ Name='DL-Partage-Secretariat-RW';  Desc='Partage Secrétariat - lecture/écriture' }
    @{ Name='DL-Partage-Imagerie-RW';     Desc='Partage Imagerie - lecture/écriture' }
    @{ Name='DL-Partage-Comptabilite-RW'; Desc='Partage Comptabilité/RH - lecture/écriture' }
    @{ Name='DL-Partage-Commun-RW';       Desc='Espace commun - lecture/écriture (tout le personnel)' }
)

# Imbrication AGDLP : quel groupe métier (global) entre dans quel groupe ressource (domaine local).
$Nesting = @(
    @{ Global='GG-Direction';    Local='DL-Partage-Direction-RW' }
    @{ Global='GG-Secretariat';  Local='DL-Partage-Secretariat-RW' }
    @{ Global='GG-Imagerie';     Local='DL-Partage-Imagerie-RW' }
    @{ Global='GG-Comptabilite'; Local='DL-Partage-Comptabilite-RW' }
    # Espace commun accessible à tous les services :
    @{ Global='GG-Direction';    Local='DL-Partage-Commun-RW' }
    @{ Global='GG-Secretariat';  Local='DL-Partage-Commun-RW' }
    @{ Global='GG-Praticiens';   Local='DL-Partage-Commun-RW' }
    @{ Global='GG-Imagerie';     Local='DL-Partage-Commun-RW' }
    @{ Global='GG-Comptabilite'; Local='DL-Partage-Commun-RW' }
    @{ Global='GG-Informatique'; Local='DL-Partage-Commun-RW' }
    @{ Global='GG-Logistique';   Local='DL-Partage-Commun-RW' }
)

# =============================== EXÉCUTION ===================================
Write-Host "`n=== MEDISOL — Provisioning AD (données fictives) ===" -ForegroundColor Cyan
Write-Host "Domaine : $($domain.DNSRoot)  ($DomainDN)`n"

# 1) Arborescence d'OU
Write-Host "--- 1. Unités d'organisation ---" -ForegroundColor Cyan
New-OUIfMissing -Name $Company             -ParentPath $DomainDN
New-OUIfMissing -Name 'Utilisateurs'       -ParentPath $BaseOUPath
New-OUIfMissing -Name 'Groupes-Metiers'    -ParentPath $BaseOUPath
New-OUIfMissing -Name 'Groupes-Ressources' -ParentPath $BaseOUPath
foreach ($svc in $Services) { New-OUIfMissing -Name $svc.OU -ParentPath $UsersOUPath }

# 2) Groupes métier (globaux)
Write-Host "`n--- 2. Groupes métier (globaux) ---" -ForegroundColor Cyan
foreach ($svc in $Services) {
    New-GroupIfMissing -Name $svc.Group -Scope Global -Path $GrpMetierOU -Description $svc.Desc
}

# 3) Groupes de ressources (domaine local)
Write-Host "`n--- 3. Groupes de ressources (domaine local) ---" -ForegroundColor Cyan
foreach ($rg in $ResourceGroups) {
    New-GroupIfMissing -Name $rg.Name -Scope DomainLocal -Path $GrpResOU -Description $rg.Desc
}

# 4) Utilisateurs + rattachement au groupe métier
Write-Host "`n--- 4. Utilisateurs ---" -ForegroundColor Cyan
foreach ($svc in $Services) {
    $ouPath = "OU=$($svc.OU),$UsersOUPath"
    Write-Host "[$($svc.OU)]" -ForegroundColor Yellow
    foreach ($u in $svc.Users) {
        New-UserIfMissing -First $u.First -Last $u.Last -Service $svc.OU -Title $u.Title -OUPath $ouPath -Group $svc.Group
    }
}

# 5) Imbrication AGDLP (groupes métier -> groupes ressources)
Write-Host "`n--- 5. Imbrication AGDLP (métier -> ressource) ---" -ForegroundColor Cyan
foreach ($n in $Nesting) {
    $already = Get-ADGroupMember -Identity $n.Local -ErrorAction SilentlyContinue |
               Where-Object { $_.SamAccountName -eq $n.Global }
    if (-not $already) {
        Add-ADGroupMember -Identity $n.Local -Members $n.Global
        Write-Host "  $($n.Global)  ->  $($n.Local)" -ForegroundColor Green
    } else {
        Write-Host "  $($n.Global)  ->  $($n.Local) (déjà fait)" -ForegroundColor DarkGray
    }
}

# 6) Récapitulatif + export CSV
Write-Host "`n--- 6. Récapitulatif ---" -ForegroundColor Cyan
Write-Host ("Utilisateurs traités : {0}" -f $script:Report.Count)
Write-Host ("Groupes métier       : {0}" -f $Services.Count)
Write-Host ("Groupes ressources   : {0}" -f $ResourceGroups.Count)
try {
    $script:Report | Sort-Object Service, Nom | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Récapitulatif exporté : $CsvPath" -ForegroundColor Green
} catch {
    Write-Warning "Export CSV impossible : $($_.Exception.Message)"
}

Write-Host "`nTerminé. Mot de passe initial commun : $DefaultPwdPlain (changement imposé à la 1re connexion).`n" -ForegroundColor Cyan
