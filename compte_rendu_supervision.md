# Supervision `/opt/supervision` — Procédures

## 1. Architecture de la stack

```
[Machine surveillée]                    [Serveur de supervision /opt/supervision]
 Telegraf (agent)  --:9273-->  Prometheus (:9090)  --évalue les règles-->  Alertmanager (:9093)  --SMTP:25-->  Postfix  --SMTP:587 auth-->  Gmail  -->  Boîte mail
 expose les métriques            scrape + stocke                          décide qui notifier        relais SMTP local      relais externe      destinataire
                                       |
                                       v
                                  Grafana (:3000)
                                  dashboards
```

Tout est orchestré par Docker Compose (`compose.yml`), qui définit les conteneurs, leurs volumes et leurs dépendances de démarrage. Toute modification de configuration se recharge avec :
```
docker compose up -d
```

| Composant | Rôle | Port | Fichier de config | Stockage |
|---|---|---|---|---|
| Telegraf | Installé sur chaque machine surveillée, collecte CPU/RAM/disque/réseau/charge + métriques OS (ex. `win_services_state` sous Windows). Ne stocke rien, expose juste les métriques au format Prometheus. | 9273 (sur la machine surveillée) | config locale à la machine | — |
| Prometheus | Scrape les cibles définies dans `scrape_configs` toutes les 15s (`scrape_interval`), stocke les séries temporelles, évalue les règles d'alerte. | 9090 | `prometheus.yml` | volume `prom_data` |
| Grafana | Source de données = Prometheus. Construit les dashboards (graphiques, jauges, tableaux d'état) à partir de requêtes PromQL. | 3000 | (dashboards en base) | volume `grafana_data` |
| Alertmanager | Reçoit les alertes `firing` de Prometheus, les regroupe, décide de l'envoi. | 9093 | `alertmanager.yml` | volume `alertmanager_data` |
| Postfix | Relais SMTP local : reçoit le mail d'Alertmanager et l'envoie authentifié vers Gmail. | — (interne) | variables d'env (`.env`, `ALLOWED_SENDER_DOMAINS`) | — |

### Comment Prometheus surveille les machines (modèle pull)

Prometheus fonctionne en **pull**, pas en push : ce n'est pas la machine surveillée qui envoie ses métriques au serveur, c'est Prometheus qui va les chercher. Concrètement, toutes les 15 secondes (`scrape_interval`), Prometheus fait une requête HTTP GET vers `http://IP_MACHINE:9273/metrics` — l'endpoint exposé en local par l'agent Telegraf. La réponse est un texte brut listant les métriques courantes (CPU, RAM, etc.).

- Si la requête réussit → la métrique `up{job="..."}` vaut `1`, et les valeurs récupérées sont stockées.
- Si elle échoue ou timeout (machine éteinte, réseau coupé, Telegraf arrêté...) → `up{job="..."}` vaut `0`.

C'est ce mécanisme de scrape HTTP répété qui fait office de "heartbeat" continu — **ce n'est ni du ping ICMP, ni du SNMP**. Aucun des deux n'est configuré dans ce projet : pas d'exporter SNMP, pas de polling SNMP (port 161/162), et le réseau n'est jamais testé par un simple ping. Tout passe par cet unique endpoint HTTP/9273 exposé par Telegraf.

Jobs Prometheus actuellement configurés (`prometheus.yml`) :
- `prometheus` (`localhost:9090`)
- `opnsense` (`192.168.60.1:9273`)
- `SDCMEDISOL` (`192.168.15.10:9273`) — AD/DNS
- `SFILESMEDISOL` (`192.168.15.20:9273`) — AD de secours / fichiers
- `srv-web` (`192.168.100.100:9273`) — ⚠️ job présent dans `prometheus.yml` mais sans dashboard dédié, voir §6.

---

## 2. Procédure : ajouter une nouvelle machine à superviser

1. **Installer Telegraf** sur la machine, configuré pour exposer ses métriques au format Prometheus sur le port `9273`.
2. **Ajouter un job** dans `prometheus.yml` :
   ```yaml
   - job_name: 'NOM_MACHINE'
     static_configs:
       - targets: ['IP_MACHINE:9273']
   ```
   Respecter l'indentation existante (voir §6 — une erreur d'indentation ici empêche Prometheus de démarrer).
3. **Recharger la stack** : `docker compose up -d`.
4. **Vérifier que la cible répond** via l'API Prometheus :
   ```
   up{job="NOM_MACHINE"}
   ```
   doit valoir `1`.
5. **Découvrir les métriques réellement exposées** par cette machine (elles varient selon l'OS et les services installés) :
   ```
   GET /api/v1/label/__name__/values
   ```
   Ne pas supposer que les mêmes métriques que sur une machine existante seront présentes — par exemple `SFILESMEDISOL` n'a pas `NTDS`/`DNS`/`Kdc`/`DFSR` (présents sur `SDCMEDISOL`), seulement `Netlogon`, `LanmanServer`, `W32Time`.
6. **Créer un dashboard Grafana dédié**, en partant d'un dashboard existant comme modèle (`POST /api/dashboards/db`), avec au minimum : statut up/down, uptime, CPU %, mémoire %, disque(s) %, trafic réseau, état des services pertinents pour cette machine.
7. **Rien à faire côté vue d'ensemble** : le dashboard "SUPERVISION_MEDISOL" utilise `up{job!="prometheus"}`, qui détecte automatiquement tout nouveau job.
8. **Rien à faire côté alerting** : les règles dans `alert.rules.yml` (§5) s'appliquent à tous les jobs sans modification, car elles se basent sur les métriques génériques (`up`, `cpu_usage_idle`, `mem_used_percent`, etc.) et non sur des noms de jobs codés en dur.

---

## 3. Procédure : diagnostiquer une panne (Prometheus, cible, ou Grafana inaccessible)

1. **Identifier le composant en panne** : Grafana (3000) et Prometheus (9090) sont indépendants — l'un peut être down sans l'autre.
2. **Consulter les logs du conteneur concerné** :
   ```
   docker compose logs prometheus
   docker compose logs grafana
   ```
3. **Cause fréquente : erreur de syntaxe dans `prometheus.yml`**. Un défaut d'indentation YAML (ex. un bloc `static_configs` indenté à 6 espaces au lieu de 4) empêche Prometheus de parser le fichier et donc de démarrer. Vérifier la cohérence d'indentation de tous les blocs `job_name`.
4. **Si le fichier appartient à `root:root`** (cas de `prometheus.yml`), l'éditer nécessite un accès `sudo` temporaire :
   ```
   sudo chown user:user /opt/supervision/prometheus.yml
   # ... édition ...
   sudo chown root:root /opt/supervision/prometheus.yml
   ```
5. **Relancer la stack** : `docker compose up -d`.
6. **Si une cible précise (et non Prometheus lui-même) semble down** : vérifier `up{job="..."}` dans Prometheus. Si `0`, le problème est côté Telegraf ou réseau sur la machine cible, pas côté serveur de supervision.

---

## 4. Procédure : dashboards Grafana

**Principe** : un dashboard dédié par machine + un dashboard de vue d'ensemble.

- Chaque dashboard dédié (ex. `sdcmedisol-ad-dns`, `sfilesmedisol-ad-files`, `opnsense-fw`) est câblé en dur sur le job correspondant.
- Le dashboard de vue d'ensemble (**SUPERVISION_MEDISOL**, uid `adk7pmx`) repose sur un seul panel *state-timeline* avec la requête :
  ```
  up{job!="prometheus"}
  ```
  `up` est générée automatiquement par Prometheus pour chaque cible scrapée (1 = répond, 0 = ne répond pas).

**Piège à éviter** : ne pas utiliser de variable de template du type `label_values(system_uptime, host)` pour un dashboard censé être dédié à une seule machine — cette requête remonte automatiquement **tous** les hôtes exposant la métrique, ce qui mélange les machines sur un même dashboard. Pour un dashboard par machine, filtrer explicitement sur le `job` concerné ; pour la vue d'ensemble, c'est au contraire le comportement recherché.

---

## 5. Procédure : alerting par email

### Fonctionnement
1. Prometheus évalue en continu `alert.rules.yml`. Chaque règle passe par trois états : `inactive` → `pending` (condition remplie, mais pas encore depuis `for:`) → `firing` (condition confirmée).
2. Alertmanager reçoit les alertes `firing`, les regroupe (`group_by`), et envoie selon `alertmanager.yml`.
3. Alertmanager envoie le mail à Postfix (SMTP non authentifié, port 25, interne au réseau Docker).
4. Postfix relaie vers Gmail (SMTP authentifié, port 587) qui délivre à `felipe.nolibois@ynov.com`.

### Règles actuelles (`alert.rules.yml`)

| Alerte | Condition | Délai (`for:`) | Sévérité |
|---|---|---|---|
| `InstanceDown` | `up == 0` | 2 min | critical |
| `HighCPUUsage` | CPU > 85 % | 5 min | warning |
| `HighMemoryUsage` | RAM > 90 % | 5 min | warning |
| `LowDiskSpace` | disque > 85 % | 10 min | warning |
| `CriticalDiskSpace` | disque > 95 % | 5 min | critical |
| `HighSystemLoad` | load1 / nb CPU > 1.5 | 5 min | warning |

Ces règles s'appliquent à toutes les machines connues sans duplication, car elles utilisent les labels génériques (`job`, `host`) déjà présents sur les métriques.

**Ajouter une règle** : éditer `alert.rules.yml`, puis `docker compose up -d` (pas de redémarrage nécessaire, Prometheus recharge le fichier de règles).

### Pourquoi un relais Gmail, et pas un envoi SMTP direct

L'IP publique du serveur est **blacklistée par Spamhaus**, ce qui fait rejeter tout envoi direct vers des domaines protégés (Microsoft/Outlook, Gmail, etc.) avec une erreur `550 ... blocked using Spamhaus`. C'est un problème de réputation de l'IP, pas de configuration. Solution retenue : transiter par un compte Gmail (`felipe.nolibois@gmail.com`), qui a une bonne réputation, via un **mot de passe d'application** (généré sur `myaccount.google.com/apppasswords`, distinct du mot de passe du compte, révocable indépendamment). Ce mot de passe est stocké dans `/opt/supervision/.env` (droits `600`), chargé par Postfix via `env_file:` — jamais en clair dans `compose.yml`.

### Pièges connus

- **`ALLOWED_SENDER_DOMAINS` doit être séparé par des espaces, pas des virgules.** Le script de démarrage du conteneur Postfix découpe cette variable sur les espaces. `supervision.local,gmail.com` est interprété comme un seul domaine inconnu → tous les mails sont rejetés (`554 5.7.1 ... Access denied`). Format correct : `ALLOWED_SENDER_DOMAINS=supervision.local gmail.com`.
- **Une alerte ne se redéclenche pas après correction d'un bug d'envoi.** Alertmanager conserve un historique des notifications déjà tentées (`nflog`) dans le volume `alertmanager_data`, pour éviter de spammer. Un envoi raté compte comme "notification tentée" — Alertmanager attend alors `repeat_interval` (4h) avant de retenter, même après redémarrage du conteneur. Pour forcer une notification immédiate :
  ```
  docker compose stop alertmanager
  docker volume rm <projet>_alertmanager_data
  docker compose up -d alertmanager
  ```

### Vérifier que l'envoi fonctionne

```
# Côté Alertmanager
docker compose logs alertmanager | grep "Notify success"

# Côté Postfix
docker compose logs postfix | grep "status=sent"
```
Un code `250 2.0.0 OK` côté Postfix confirme que Gmail a accepté et délivré le message.

---

## 6. Points de vigilance

- **`prometheus.yml` appartient à `root:root`** : toute modification nécessite un `chown` temporaire (§3, étape 4).
- **Un dashboard dédié doit être créé manuellement pour chaque nouvelle machine** — la vue d'ensemble se met à jour seule, mais pas les dashboards individuels.
- **Job `srv-web` (`192.168.100.100:9273`) présent dans `prometheus.yml` sans dashboard dédié.** À traiter avec la procédure §2 (étapes 5 à 6) : vérifier les métriques exposées puis créer le dashboard.
- **Dépendance au compte Gmail personnel** : si le mot de passe d'application est révoqué ou le compte change, l'envoi d'alertes s'arrête silencieusement (Postfix met les mails en échec/attente). Régénérer le mot de passe sur `myaccount.google.com/apppasswords`, mettre à jour `.env`, puis `docker compose up -d postfix`.
- **IP publique blacklistée Spamhaus** : un retrait est demandable via `spamhaus.org/query/ip/...`, mais en attendant, le relais Gmail reste nécessaire pour tout envoi vers Microsoft/Google et assimilés.
