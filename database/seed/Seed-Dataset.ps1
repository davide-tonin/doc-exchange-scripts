# The UI seed dataset: who exists, how much of everything they have, and what it is all called.
# Display names land in every list, header, party chip and share dialog, so they are written to
# look like real Italian/EU B2B counterparties of visibly different sizes.
#
# See doc-exchange-service\docs\UI_SEED_DATASET.md for why each quantity is what it is.

Set-StrictMode -Version 2.0

# Service-side caps the volumes are aimed at (AliasValidator, IdentityValidator, RoleValidator,
# PovValidator, GroupValidator, ShapeValidator). Kept here so a drift shows up as a failed
# cap fixture rather than a silent nothing.
$script:SeedCaps = @{
    Aliases    = 25
    Identities = 100
    Roles      = 100
    Povs       = 100
    Groups     = 100
    Shapes     = 50
}

$script:SeedGivenNames = @(
    "Giulia", "Marco", "Elena", "Davide", "Sara", "Luca", "Chiara", "Alessandro",
    "Federica", "Matteo", "Silvia", "Andrea", "Valentina", "Stefano", "Martina",
    "Francesco", "Alice", "Riccardo", "Beatrice", "Tommaso", "Ilaria", "Giovanni",
    "Camilla", "Pietro", "Arianna", "Filippo", "Noemi", "Emanuele", "Gaia", "Nicola",
    "Serena", "Lorenzo", "Irene", "Simone", "Marta", "Fabio", "Alessia", "Daniele",
    "Roberta", "Enrico"
)

$script:SeedFamilyNames = @(
    "Bernardi", "Ferretti", "Costa", "Neri", "Fontana", "Moretti", "Gallo", "Rizzo",
    "Longo", "Greco", "Marchetti", "Barbieri", "Villa", "Sanna", "Colombo", "Ricci",
    "Bruno", "Gatti", "Serra", "Palmieri", "Vitale", "Farina", "Rinaldi", "Caruso",
    "Mancini", "Pellegrini", "Testa", "Grassi", "Monti", "Battaglia", "Sartori",
    "Bianchi", "Donati", "Lombardi", "Orlando", "Pagano", "Riva", "Silvestri",
    "Valentini", "Zanetti"
)

# Roughly a quarter of real directory entries carry a department suffix. Included so the UI
# is exercised against names that are long and punctuated, not just "Mario Rossi".
$script:SeedDepartments = @(
    "Fatturazione", "Logistica", "Acquisti", "Amministrazione", "Magazzino",
    "Qualita", "Dogane", "Legale", "IT", "Controllo di Gestione"
)

$script:SeedServiceIdentityNames = @(
    "SAP IDoc Bridge", "Portale Fornitori", "EDI Gateway (AS2)", "Nightly Reconciler",
    "Warehouse Scanner Fleet", "Billing Robot", "Archivio Sostitutivo Connector",
    "Peppol Access Point", "Corriere Tracking Poller", "ERP Batch Loader"
)

# Realistic, deliberately non-uniform permission sets. An all-or-nothing seed makes every
# permission-gated screen look identical.
$script:SeedRoleCatalog = @(
    @{ Name = "Billing Operator";           Description = "Emette e consulta documenti di fatturazione.";        Allow = @("DOC_SEND", "DOC_READ", "ALIAS_READ", "SHAPE_READ") },
    @{ Name = "AP Clerk (read-only)";       Description = "Sola lettura sul ciclo passivo.";                     Allow = @("DOC_READ", "ALIAS_READ", "IDENTITY_READ") },
    @{ Name = "EDI Integrator";             Description = "Integrazione EDI e gestione shape.";                  Allow = @("DOC_SEND", "DOC_READ", "SHAPE_READ", "SHAPE_CREATE", "ALIAS_READ") },
    @{ Name = "Compliance Auditor";         Description = "Accesso storico completo, nessuna scrittura.";        Allow = @("DOC_READ", "IDENTITY_READ", "IDENTITY_HISTORY", "ROLE_READ", "ROLE_HISTORY", "ALIAS_READ", "ALIAS_HISTORY", "GROUP_READ", "GROUP_HISTORY", "POV_READ", "POV_HISTORY") },
    @{ Name = "Warehouse Dispatcher";       Description = "Spedizioni e DDT dal magazzino.";                     Allow = @("DOC_SEND", "DOC_READ", "GROUP_READ") },
    @{ Name = "Customs Broker";             Description = "Pratiche doganali e gruppi di controparti.";          Allow = @("DOC_SEND", "DOC_READ", "ALIAS_READ", "GROUP_READ", "POV_READ") },
    @{ Name = "Partner (read-only)";        Description = "Accesso minimo per controparti esterne.";             Allow = @("DOC_READ") },
    @{ Name = "Invoice Approver";           Description = "Approva e inoltra fatture in ciclo passivo.";         Allow = @("DOC_READ", "DOC_SEND", "IDENTITY_ROLE_READ") },
    @{ Name = "Support Engineer";           Description = "Diagnostica di sola lettura sulla configurazione.";   Allow = @("IDENTITY_READ", "ROLE_READ", "POV_READ", "TENANT_SETTINGS_READ") },
    @{ Name = "Tenant Admin (delegato)";    Description = "Amministrazione delegata senza invio documenti.";     Allow = @("IDENTITY_CREATE", "IDENTITY_READ", "IDENTITY_UPDATE", "ROLE_CREATE", "ROLE_READ", "ROLE_UPDATE", "IDENTITY_ROLE_CREATE", "IDENTITY_ROLE_READ", "TENANT_SETTINGS_READ", "TENANT_SETTINGS_UPDATE") }
)

$script:SeedPovCatalog = @(
    @{ Name = "Inbox - tutti";                   Description = "Tutti i documenti ricevuti.";                        TenantRole = "RECIPIENT"; Months = 36 },
    @{ Name = "Inbox - fatture";                 Description = "Solo fatture ricevute.";                             TenantRole = "RECIPIENT"; Months = 24; ShapePrefix = "fattura" },
    @{ Name = "Dichiarazioni doganali";          Description = "Documenti doganali ricevuti.";                       TenantRole = "RECIPIENT"; Months = 24; ShapePrefix = "dichiarazione" },
    @{ Name = "Archivio CC";                     Description = "Documenti ricevuti per conoscenza.";                 TenantRole = "CC";        Months = 36 },
    @{ Name = "Inviati - ultimi 90 giorni";      Description = "Traffico in uscita recente.";                        TenantRole = "SENDER";    Months = 3 },
    @{ Name = "Inviati - ordini";                Description = "Ordini di acquisto emessi.";                         TenantRole = "SENDER";    Months = 24; ShapePrefix = "ordine" },
    @{ Name = "Trasporti e DDT";                 Description = "Documenti di trasporto ricevuti.";                   TenantRole = "RECIPIENT"; Months = 18; ShapePrefix = "documento di trasporto" },
    @{ Name = "Con oggetto valorizzato";         Description = "Solo documenti che riportano un oggetto.";           TenantRole = "RECIPIENT"; Months = 36; SubjectPresent = $true },
    @{ Name = "Storico completo";                Description = "Finestra aperta su tutto lo storico.";               TenantRole = "RECIPIENT"; Months = 120 },
    @{ Name = "Rilasci lotto";                   Description = "Rilasci di lotto farmaceutico ricevuti.";            TenantRole = "RECIPIENT"; Months = 24; ShapePrefix = "rilascio" }
)

# Real JSON Schema (Draft 2020-12 — ShapeSchemaCodec's default dialect). The send payloads in
# Seed-Phases.ps1 are generated to satisfy these, so schema and generator move together.
$script:SeedShapeCatalog = @(
    @{
        Name = "Fattura Elettronica PA"
        Description = "Fattura elettronica verso la pubblica amministrazione."
        Schema = @{
            type = "object"
            required = @("numero", "data", "imponibile", "iva", "totale")
            properties = @{
                numero     = @{ type = "string" }
                data       = @{ type = "string" }
                imponibile = @{ type = "number" }
                iva        = @{ type = "number" }
                totale     = @{ type = "number" }
                cig        = @{ type = "string" }
                note       = @{ type = "string" }
            }
        }
    },
    @{
        Name = "Ordine di Acquisto"
        Description = "Ordine di acquisto verso un fornitore."
        Schema = @{
            type = "object"
            required = @("numero_ordine", "data", "righe")
            properties = @{
                numero_ordine = @{ type = "string" }
                data          = @{ type = "string" }
                consegna      = @{ type = "string" }
                righe = @{
                    type = "array"
                    items = @{
                        type = "object"
                        required = @("codice", "quantita", "prezzo")
                        properties = @{
                            codice      = @{ type = "string" }
                            descrizione = @{ type = "string" }
                            quantita    = @{ type = "number" }
                            prezzo      = @{ type = "number" }
                        }
                    }
                }
            }
        }
    },
    @{
        Name = "Documento di Trasporto"
        Description = "DDT per spedizioni merce."
        Schema = @{
            type = "object"
            required = @("numero_ddt", "data", "vettore", "colli")
            properties = @{
                numero_ddt  = @{ type = "string" }
                data        = @{ type = "string" }
                vettore     = @{ type = "string" }
                colli       = @{ type = "integer" }
                peso_kg     = @{ type = "number" }
                destinazione = @{ type = "string" }
            }
        }
    },
    @{
        Name = "Lettera di Vettura CMR"
        Description = "CMR per trasporto internazionale su strada."
        Schema = @{
            type = "object"
            required = @("cmr", "mittente", "destinatario", "luogo_carico")
            properties = @{
                cmr           = @{ type = "string" }
                mittente      = @{ type = "string" }
                destinatario  = @{ type = "string" }
                luogo_carico  = @{ type = "string" }
                luogo_scarico = @{ type = "string" }
                targa         = @{ type = "string" }
            }
        }
    },
    @{
        Name = "Dichiarazione Doganale Export"
        Description = "Dichiarazione di esportazione."
        Schema = @{
            type = "object"
            required = @("mrn", "regime", "valore_statistico", "paese_destinazione")
            properties = @{
                mrn                = @{ type = "string" }
                regime             = @{ type = "string" }
                valore_statistico  = @{ type = "number" }
                paese_destinazione = @{ type = "string" }
                voce_doganale      = @{ type = "string" }
            }
        }
    },
    @{
        Name = "Rilascio Lotto Farmaceutico"
        Description = "Certificato di rilascio lotto (GMP)."
        Schema = @{
            type = "object"
            required = @("lotto", "aic", "data_rilascio", "esito")
            properties = @{
                lotto         = @{ type = "string" }
                aic           = @{ type = "string" }
                data_rilascio = @{ type = "string" }
                esito         = @{ type = "string"; enum = @("CONFORME", "NON_CONFORME") }
                qp            = @{ type = "string" }
            }
        }
    },
    @{
        Name = "Notifica Legale"
        Description = "Comunicazione legale con valore di notifica."
        Schema = @{
            type = "object"
            required = @("protocollo", "oggetto", "corpo")
            properties = @{
                protocollo = @{ type = "string" }
                oggetto    = @{ type = "string" }
                corpo      = @{ type = "string" }
                allegati   = @{ type = "array"; items = @{ type = "string" } }
            }
        }
    },
    @{
        Name = "Conferma Ordine"
        Description = "Conferma d'ordine dal fornitore."
        Schema = @{
            type = "object"
            required = @("ordine_riferimento", "stato")
            properties = @{
                ordine_riferimento = @{ type = "string" }
                stato              = @{ type = "string"; enum = @("ACCETTATO", "PARZIALE", "RIFIUTATO") }
                data_consegna      = @{ type = "string" }
                note               = @{ type = "string" }
            }
        }
    }
)

$script:SeedGroupCatalog = @(
    @{ Name = "Fornitori certificati";      Entity = "ALIAS";    Description = "Alias dei fornitori qualificati." },
    @{ Name = "Team Fatturazione";          Entity = "IDENTITY"; Description = "Chi lavora il ciclo attivo." },
    @{ Name = "Turno notturno magazzino";   Entity = "IDENTITY"; Description = "Operatori del turno notte." },
    @{ Name = "Ruoli operativi";            Entity = "ROLE";     Description = "Ruoli non amministrativi." },
    @{ Name = "Enti pubblici";              Entity = "TENANT";   Description = "Controparti della PA." },
    @{ Name = "Clienti Nord Italia";        Entity = "ALIAS";    Description = "Clienti serviti dal deposito di Verona." },
    @{ Name = "Referenti dogana";           Entity = "IDENTITY"; Description = "Chi segue le pratiche doganali." },
    @{ Name = "Ruoli in dismissione";       Entity = "ROLE";     Description = "Ruoli da rivedere entro fine anno." }
)

$script:SeedPartyGroupCatalog = @(
    @{ Name = "Distribuzione DDT - Lombardia"; Description = "Destinatari abituali dei DDT lombardi." },
    @{ Name = "Notifiche doganali";            Description = "Enti da mettere in copia sulle pratiche." },
    @{ Name = "Broadcast fornitori";           Description = "Comunicazioni massive ai fornitori." }
)

<#
.SYNOPSIS
The full seed definition: tenant cast, per-tenant volumes, and the cross-tenant matrix.

.PARAMETER Scale
Full is the real dataset. Fast shrinks every volume for a quick iteration loop while keeping
the same shape — same tenants, same relationships, same edge states, fewer rows.
#>
function Get-SeedDataset
{
    param(
        [ValidateSet("Full", "Fast")] [string] $Scale = "Full",
        [string] $EmailDomain = "davide.eu"
    )

    $caps = $script:SeedCaps

    # Volumes are TOTALS including what fn_tenant_bootstrap already created (1 identity,
    # 2 roles, 1 POV, 1 canonical alias per tenant).
    $tenants = @(
        [ordered]@{
            Key = "aurora"; DisplayName = "Aurora Logistics S.r.l."; Type = "COMPANY"
            Email = "postman_tenant_1@$EmailDomain"; Domain = "auroralogistics.it"
            Note = "Flagship: near every cap, multi-page everything."
            Identities = 92; Roles = 40; Povs = 24; Shapes = 18; Aliases = 22; Groups = 55; Sends = 260
            EmailAliases = @("fatture@auroralogistics.it", "ordini@auroralogistics.it", "ddt@auroralogistics.it")
            VatId = "IT02458760231"
            Credentialed = 3
        },
        [ordered]@{
            Key = "lumen"; DisplayName = "Lumen Consulting S.r.l."; Type = "COMPANY"
            Email = "postman_tenant_2@$EmailDomain"; Domain = "lumenconsulting.it"
            Note = "Peer: the cross-tenant partner."
            Identities = 24; Roles = 12; Povs = 8; Shapes = 6; Aliases = 9; Groups = 14; Sends = 120
            EmailAliases = @("amministrazione@lumenconsulting.it")
            VatId = "IT01923470287"
            Credentialed = 3
        },
        [ordered]@{
            Key = "bellini"; DisplayName = "Bellini Farmaceutici S.p.A."; Type = "COMPANY"
            Email = "seed_bellini@$EmailDomain"; Domain = "bellinifarma.it"
            Note = "Heavy sender on regulated shapes."
            Identities = 24; Roles = 12; Povs = 8; Shapes = 6; Aliases = 9; Groups = 14; Sends = 180
            EmailAliases = @("pec@bellinifarma.it", "qualita@bellinifarma.it")
            VatId = "IT00778890152"
            Credentialed = 3
        },
        [ordered]@{
            Key = "verona"; DisplayName = "Comune di Verona"; Type = "GOVERNMENT"
            Email = "seed_verona@$EmailDomain"; Domain = "comune.verona.it"
            Note = "Public body: receive-heavy."
            Identities = 12; Roles = 6; Povs = 5; Shapes = 3; Aliases = 6; Groups = 6; Sends = 20
            EmailAliases = @("protocollo@comune.verona.it")
            VatId = "IT00215560232"
            Credentialed = 1
        },
        [ordered]@{
            Key = "dogane"; DisplayName = "Agenzia Dogane - Ufficio di Trieste"; Type = "GOVERNMENT"
            Email = "seed_dogane@$EmailDomain"; Domain = "adm.gov.it"
            Note = "Customs: the second GOVERNMENT tenant."
            Identities = 12; Roles = 6; Povs = 5; Shapes = 3; Aliases = 6; Groups = 6; Sends = 40
            EmailAliases = @("dogane.trieste@adm.gov.it")
            VatId = "IT06373941006"
            Credentialed = 1
        },
        [ordered]@{
            Key = "ferrari"; DisplayName = "Studio Legale Ferrari & Associati"; Type = "COMPANY"
            Email = "seed_ferrari@$EmailDomain"; Domain = "studioferrari.it"
            Note = "Small firm: sparse lists."
            Identities = 3; Roles = 2; Povs = 2; Shapes = 1; Aliases = 3; Groups = 1; Sends = 8
            EmailAliases = @("segreteria@studioferrari.it")
            VatId = "IT03310980284"
            Credentialed = 1
        },
        [ordered]@{
            Key = "ricci"; DisplayName = "Marta Ricci"; Type = "USER"
            Email = "seed_ricci@$EmailDomain"; Domain = "martaricci.it"
            Note = "The USER tenant type: one person, no staff."
            Identities = 1; Roles = 2; Povs = 1; Shapes = 0; Aliases = 2; Groups = 0; Sends = 3
            EmailAliases = @("marta@martaricci.it")
            VatId = "IT04412330273"
            Credentialed = 0
        },
        [ordered]@{
            Key = "nordwind"; DisplayName = "Nordwind Spedition GmbH"; Type = "COMPANY"
            Email = "seed_nordwind@$EmailDomain"; Domain = "nordwind-spedition.de"
            Note = "Foreign counterparty: non-Italian VAT format."
            Identities = 8; Roles = 4; Povs = 3; Shapes = 2; Aliases = 4; Groups = 3; Sends = 45
            EmailAliases = @("dispo@nordwind-spedition.de")
            VatId = "DE811907980"
            Credentialed = 1
        },
        [ordered]@{
            Key = "cormorano"; DisplayName = "Cormorano Trasporti S.r.l."; Type = "COMPANY"
            Email = "seed_cormorano@$EmailDomain"; Domain = "cormoranotrasporti.it"
            Note = "Deliberately AT every hard cap so the UI's limit errors are reachable."
            Identities = $caps.Identities; Roles = $caps.Roles; Povs = $caps.Povs
            Shapes = $caps.Shapes; Aliases = $caps.Aliases; Groups = $caps.Groups; Sends = 15
            EmailAliases = @("info@cormoranotrasporti.it")
            VatId = "IT02998760962"
            Credentialed = 1
            AtCap = $true
        },
        [ordered]@{
            Key = "murano"; DisplayName = "Vetreria Murano S.r.l."; Type = "COMPANY"
            Email = "seed_murano@$EmailDomain"; Domain = "vetreriamurano.it"
            Note = "Bootstrap only: every list empty, for the empty-state screens."
            Identities = 1; Roles = 2; Povs = 1; Shapes = 0; Aliases = 1; Groups = 0; Sends = 0
            EmailAliases = @()
            VatId = $null
            Credentialed = 0
        }
    )

    if ($Scale -eq "Fast")
    {
        foreach ($tenant in $tenants)
        {
            # Cormorano keeps its real caps even in Fast: the cap fixtures are the point of it.
            if ($tenant.Contains("AtCap") -and $tenant.AtCap) { $tenant.Sends = 5; continue }
            foreach ($field in @("Identities", "Roles", "Povs", "Shapes", "Aliases", "Groups", "Sends"))
            {
                $tenant[$field] = [Math]::Max(1, [int][Math]::Ceiling($tenant[$field] / 6))
            }
            $tenant.Credentialed = [Math]::Min($tenant.Credentialed, 1)
        }
        # Murano must stay empty at any scale.
        $murano = $tenants | Where-Object { $_.Key -eq "murano" }
        $murano.Identities = 1; $murano.Roles = 2; $murano.Povs = 1
        $murano.Shapes = 0; $murano.Aliases = 1; $murano.Groups = 0; $murano.Sends = 0
    }

    # Owner shares an identity into a grantee tenant; the grantee then grants its own role and
    # POV back to it. Covers both status sides, share-without-grant, SERVICE_ACCOUNT identity sharing,
    # and GOVERNMENT<->COMPANY in both directions.
    $shares = @(
        @{ Owner = "aurora";   Grantee = "lumen";   Subject = "admin";   Grant = $true;  OwnerStatus = "ENABLED";  GranteeStatus = "ENABLED" },
        @{ Owner = "aurora";   Grantee = "bellini"; Subject = "human";   Grant = $true;  OwnerStatus = "ENABLED";  GranteeStatus = "ENABLED" },
        @{ Owner = "bellini";  Grantee = "aurora";  Subject = "service"; Grant = $true;  OwnerStatus = "ENABLED";  GranteeStatus = "ENABLED" },
        @{ Owner = "lumen";    Grantee = "verona";  Subject = "admin";   Grant = $true;  OwnerStatus = "ENABLED";  GranteeStatus = "DISABLED" },
        @{ Owner = "nordwind"; Grantee = "dogane";  Subject = "human";   Grant = $true;  OwnerStatus = "ENABLED";  GranteeStatus = "ENABLED" },
        @{ Owner = "dogane";   Grantee = "aurora";  Subject = "admin";   Grant = $false; OwnerStatus = "ENABLED";  GranteeStatus = "ENABLED" },
        @{ Owner = "verona";   Grantee = "ferrari"; Subject = "admin";   Grant = $false; OwnerStatus = "DISABLED"; GranteeStatus = "ENABLED" }
    )

    # Who sends to whom, and roughly how the inbox depth ends up distributed.
    $trafficWeights = @{
        aurora    = @{ lumen = 3; bellini = 2; verona = 4; dogane = 2; nordwind = 2; ferrari = 1; ricci = 1; cormorano = 1 }
        lumen     = @{ aurora = 4; verona = 2; ferrari = 1; bellini = 1 }
        bellini   = @{ aurora = 5; verona = 3; dogane = 2; nordwind = 1; lumen = 1 }
        verona    = @{ aurora = 2; lumen = 1; ferrari = 1 }
        dogane    = @{ aurora = 2; nordwind = 3; bellini = 1 }
        ferrari   = @{ verona = 2; aurora = 1 }
        ricci     = @{ aurora = 1; ferrari = 1 }
        nordwind  = @{ aurora = 3; dogane = 2; bellini = 1 }
        cormorano = @{ aurora = 2; lumen = 1 }
        murano    = @{}
    }

    return [ordered]@{
        Scale             = $Scale
        Caps              = $caps
        Tenants           = $tenants
        Shares            = $shares
        TrafficWeights    = $trafficWeights
        GivenNames        = $script:SeedGivenNames
        FamilyNames       = $script:SeedFamilyNames
        Departments       = $script:SeedDepartments
        ServiceNames      = $script:SeedServiceIdentityNames
        RoleCatalog       = $script:SeedRoleCatalog
        PovCatalog        = $script:SeedPovCatalog
        ShapeCatalog      = $script:SeedShapeCatalog
        GroupCatalog      = $script:SeedGroupCatalog
        PartyGroupCatalog = $script:SeedPartyGroupCatalog
    }
}
