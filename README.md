# IPQuality

Dual-Stack (IPv4 + IPv6) IP Reputation, GeoIP Consensus, Streaming/AI Unlock, CDN Edge & DNSBL Diagnostics Script.

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

## Optional Custom API Keys
You can optionally pass your own API keys via environment variables for higher rate limits:
- `IPINFO_TOKEN` — ipinfo.io API token
- `IPREGISTRY_KEY` — ipregistry.co API key
- `IPDATA_KEY` — ipdata.co API key
- `ABUSEIPDB_KEY` — AbuseIPDB APIv2 key
- `IPQS_KEY` — IPQualityScore API key
- `IP2LOCATION_KEY` — IP2Location.io API key
- `PROXYCHECK_KEY` — proxycheck.io API key
