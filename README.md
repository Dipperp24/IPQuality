# IPQuality

Dual-Stack (IPv4 + IPv6) IP Reputation, BGP/RPKI Routing, Fraud Score, Streaming/AI/Platform Unlock, CDN Edge, Server Telemetry & DNSBL Diagnostics Script.

## Features
- **I. Basic Information & BGP Routing** — ASN, Announced BGP Prefix, Anycast detection, RPKI ROA validity, Upstream Transit Peers (Tier-1 / IX labels), GeoIP & rDNS (PTR).
- **II. IP Type Classification (12 Databases)** — Usage & Company type across IPinfo, ipregistry, ipapi.is, IP2Location, ipdata.co, ipwho.is, MaxMind, AbuseIPDB, ProxyCheck, ip-api.com, ipquery.io, Scamalytics.
- **III. Fraud & Abuse Risk Scores (10 Engines)** — Visual 256-color gauge bars for Scamalytics, IPQualityScore, ipquery.io, IP2Location, AbuseIPDB, ProxyCheck.io, ipapi.is, ipregistry.co, ipdata.co, DB-IP.
- **IV. Security & Risk Factors (8 Sources)** — Country consensus, Proxy, VPN, Tor, Datacenter/Server, Abuser, and Robot/Crawler flags.
- **V. Streaming, AI & Web Accessibility** — TikTok, Disney+, Netflix, YouTube, Spotify, Twitch, ChatGPT, Gemini, Claude, xAI Grok, Cloudflare, Google, Reddit, Wikipedia (Rangeblock check), Steam, Instagram, GitHub API rate-limit, and Telegram API.
- **VI. CDN Edge Nodes** — Closest Anycast POPs for Cloudflare, YouTube (GGC), Netflix (OCA), Fastly, and AWS CloudFront.
- **VII. Email Connectivity & DNSBL** — Local Port 25 outbound check, MX TCP reachability (Gmail, Outlook, Yahoo, Apple, Proton, Yandex, Mail.ru, Zoho), and 10 DNSBL spam blacklists.
- **VIII. Server Network & Routing Telemetry** — Direct Public IP vs NAT detection, virtualization type, Linux kernel & TCP congestion control (BBR check), Outbound DNS (EDNS leak check), and Anycast RTT latency (Cloudflare, Google, Quad9).
- **Overall IP Quality Verdict** — Aggregated Trust Score (`0–100`) and letter Grade (`A+` to `F`).

## Quick Run (Dual-Stack IPv4 + IPv6)
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh)
```

## Options & Examples

### IPv4 Only
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh) -4
```

### IPv6 Only
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh) -6
```

### Check Custom IP (IPv4 or IPv6)
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh) -i 1.1.1.1
```

### Mask IP Address in Report
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh) -m
```

### Save Clean Text Report to File
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh) -o report.txt
```

### Direct Queries Only (Disable Aggregator Fallback)
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh) --direct
```

### Low-Resource VPS (Limit Concurrent Connections)
On small VPS instances (1 vCPU, limited bandwidth/conntrack), limit concurrent background requests:
```bash
IPQ_PARALLEL=4 bash <(curl -Ls https://raw.githubusercontent.com/Dipperp24/IPQuality/main/ipcheck.sh)
```

## Optional Custom API Keys
You can optionally pass your own API keys via environment variables for higher rate limits or enterprise tiers (by default, the script works out of the box using keyless public demos and direct endpoints for MaxMind, IP2Location, Scamalytics, ipwhois, ProxyCheck, ip-api, ipquery, and IPinfo):
- `IPINFO_TOKEN` — ipinfo.io API token
- `IPREGISTRY_KEY` — ipregistry.co API key
- `IPDATA_KEY` — ipdata.co API key
- `IPAPI_KEY` — ipapi.is API key
- `ABUSEIPDB_KEY` — AbuseIPDB APIv2 key
- `IPQS_KEY` — IPQualityScore API key
- `IP2LOCATION_KEY` — IP2Location.io API key
- `PROXYCHECK_KEY` — proxycheck.io API key
- `DBIP_KEY` — db-ip.com API key
