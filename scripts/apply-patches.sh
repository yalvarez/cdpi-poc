#!/usr/bin/env bash
# Re-applies all CREDEBL container patches (idempotent).
# Run from within /home/apps/cdpi-poc/credebl directory.
set -euo pipefail

echo "=== Re-applying all CREDEBL container patches ==="

# ---------- Patch 1: Utility S3 -> MinIO ----------
# The utility service has 3 S3 clients using different env var groups.
# Each needs endpoint and s3ForcePathStyle to target MinIO instead of AWS.
echo -n "Patch 1 (utility S3->MinIO, 3 clients): "
docker exec --user root credebl-utility node -e "
var fs=require('fs');
var p='/app/dist/apps/utility/main.js';
var c=fs.readFileSync(p,'utf8');
if(c.includes('PATCH: S3 MinIO')){process.stdout.write('already patched\n');process.exit(0);}
var patches=0;
var t1='accessKeyId: process.env.AWS_ACCESS_KEY,\n            secretAccessKey: process.env.AWS_SECRET_KEY,\n            region: process.env.AWS_REGION\n        });';
if(c.includes(t1)){c=c.replace(t1,'accessKeyId: process.env.AWS_ACCESS_KEY,\n            secretAccessKey: process.env.AWS_SECRET_KEY,\n            region: process.env.AWS_REGION,\n            endpoint: process.env.AWS_ENDPOINT,\n            s3ForcePathStyle: true /* PATCH: S3 MinIO */\n        });');patches++;}
var t2='accessKeyId: process.env.AWS_PUBLIC_ACCESS_KEY,\n            secretAccessKey: process.env.AWS_PUBLIC_SECRET_KEY,\n            region: process.env.AWS_PUBLIC_REGION\n        });';
if(c.includes(t2)){c=c.replace(t2,'accessKeyId: process.env.AWS_PUBLIC_ACCESS_KEY,\n            secretAccessKey: process.env.AWS_PUBLIC_SECRET_KEY,\n            region: process.env.AWS_PUBLIC_REGION,\n            endpoint: process.env.AWS_ENDPOINT,\n            s3ForcePathStyle: true\n        });');patches++;}
var t3='accessKeyId: process.env.AWS_S3_STOREOBJECT_ACCESS_KEY,\n            secretAccessKey: process.env.AWS_S3_STOREOBJECT_SECRET_KEY,\n            region: process.env.AWS_S3_STOREOBJECT_REGION\n        });';
if(c.includes(t3)){c=c.replace(t3,'accessKeyId: process.env.AWS_S3_STOREOBJECT_ACCESS_KEY,\n            secretAccessKey: process.env.AWS_S3_STOREOBJECT_SECRET_KEY,\n            region: process.env.AWS_S3_STOREOBJECT_REGION,\n            endpoint: process.env.AWS_S3_STOREOBJECT_ENDPOINT,\n            s3ForcePathStyle: true\n        });');patches++;}
if(patches===0){process.stderr.write('ERROR: no S3 client targets found\n');process.exit(1);}
fs.writeFileSync(p,c);
process.stdout.write('patched '+patches+' clients\n');
" 2>&1
echo -n "  -> restart utility: "
docker restart credebl-utility > /dev/null 2>&1 && echo "ok"

# ---------- Patch 2: API gateway require_tld ----------
echo -n "Patch 2 (api-gateway @context validator): "
docker exec --user root credebl-api-gateway node -e "
var fs=require('fs');
var p='/app/dist/apps/api-gateway/main.js';
var c=fs.readFileSync(p,'utf8');
if(c.includes('require_tld:false')){process.stdout.write('already patched\n');process.exit(0);}
var t='isURL(v)';
if(!c.includes(t)){process.stderr.write('target not found\n');process.exit(1);}
c=c.split(t).join('isURL(v,{require_tld:false})');
fs.writeFileSync(p,c);
process.stdout.write('patched\n');
" 2>&1
echo -n "  -> restart api-gateway: "
docker restart credebl-api-gateway > /dev/null 2>&1 && echo "ok"

# ---------- Patch 4: Issuance schema URL dedup ----------
echo -n "Patch 4 (issuance schema URL dedup): "
docker exec --user root credebl-issuance node -e "
var fs=require('fs');
var p='/app/dist/apps/issuance/main.js';
var c=fs.readFileSync(p,'utf8');
if(c.includes('PATCH: schema URL dedup')){process.stdout.write('already patched\n');process.exit(0);}
var t='async getW3CSchemaAttributes(schemaUrl';
var idx=c.indexOf(t);
if(idx<0){process.stderr.write('target not found\n');process.exit(1);}
var ins='while(schemaUrl.indexOf(\"://http\")>0){schemaUrl=schemaUrl.slice(schemaUrl.indexOf(\"://http\")+3);} /* PATCH: schema URL dedup */\n';
var bIdx=c.indexOf('{',idx)+1;
c=c.slice(0,bIdx)+ins+c.slice(bIdx);
fs.writeFileSync(p,c);
process.stdout.write('patched\n');
" 2>&1

# ---------- Patch 5: Issuance @context normalize ----------
echo -n "Patch 5 (issuance context normalize): "
docker exec --user root credebl-issuance node -e "
var fs=require('fs');
var p='/app/dist/apps/issuance/main.js';
var c=fs.readFileSync(p,'utf8');
if(c.includes('ctx.map(function(url)')){process.stdout.write('already patched\n');process.exit(0);}
var t=\"this.logger.debug('Validated/Updated Issuance dates credential offer')\";
if(!c.includes(t)){process.stderr.write('target not found\n');process.exit(1);}
var ins=\"\nif(offer.credential&&Array.isArray(offer.credential['@context'])){offer.credential['@context']=offer.credential['@context'].map(function(url){if(typeof url==='string'){while(url.indexOf('://http')>0){url=url.slice(url.indexOf('://http')+3);}}return url;});} /* ctx.map(function(url) PATCH */\n\";
c=c.replace(t,t+ins);
fs.writeFileSync(p,c);
process.stdout.write('patched\n');
" 2>&1
echo -n "  -> restart issuance: "
docker restart credebl-issuance > /dev/null 2>&1 && echo "ok"

# ---------- Patch 3: Credo CredentialEvents ----------
CREDO=$(docker ps --format '{{.Names}}' | grep -v '^credebl-' | head -1)
echo "  Credo container: $CREDO"
echo -n "Patch 3 (Credo CredentialEvents): "
docker exec --user root "$CREDO" node -e "
var fs=require('fs');
var p='/app/build/events/CredentialEvents.js';
var c=fs.readFileSync(p,'utf8');
if(c.includes('credentials try-catch guard')){process.stdout.write('already patched\n');process.exit(0);}
if(c.includes('getFormatData unavailable')){process.stdout.write('already patched (upstream)\n');process.exit(0);}
var t='const data = await tenantAgent.credentials.getFormatData(record.id);\n            body.credentialData = data;';
if(!c.includes(t)){process.stderr.write('target not found\n');process.exit(1);}
c=c.replace(t,'try { if (tenantAgent && tenantAgent.credentials) { const data = await tenantAgent.credentials.getFormatData(record.id); body.credentialData = data; } } catch (e) { /* credentials try-catch guard */ }');
fs.writeFileSync(p,c);
process.stdout.write('patched\n');
" 2>&1
# Only restart Credo if just patched (restart invalidates tenant JWT)
CREDO_RESULT=$(docker exec --user root "$CREDO" node -e "
var c=require('fs').readFileSync('/app/build/events/CredentialEvents.js','utf8');
process.stdout.write(c.includes('credentials try-catch guard')?'ok':'missing');
" 2>/dev/null)
if [ "$CREDO_RESULT" = "ok" ]; then
  echo "  (Credo CredentialEvents patch confirmed)"
fi

# ---------- Patch 7: Credo ProofEvents ----------
echo -n "Patch 7 (Credo ProofEvents): "
docker exec --user root "$CREDO" node -e "
var fs=require('fs');
var p='/app/build/events/ProofEvents.js';
var c=fs.readFileSync(p,'utf8');
if(c.includes('proofData try-catch guard')){process.stdout.write('already patched\n');process.exit(0);}
var tA='tenantId: event.metadata.contextCorrelationId,';
if(c.includes(tA)){c=c.replace(tA,\"tenantId: event.metadata.contextCorrelationId.indexOf('tenant-')===0?event.metadata.contextCorrelationId.slice(7):event.metadata.contextCorrelationId, // tenant- prefix guard\");}
var tB='const data = await tenantAgent.proofs.getFormatData(record.id);\n            body.proofData = data;';
if(c.includes(tB)){c=c.replace(tB,'try { if (tenantAgent && tenantAgent.proofs) { const data = await tenantAgent.proofs.getFormatData(record.id); body.proofData = data; } } catch (e) { /* proofData try-catch guard */ }');}
if(!c.includes('proofData try-catch guard')){process.stderr.write('ERROR: patch target not found\n');process.exit(1);}
fs.writeFileSync(p,c);
process.stdout.write('patched\n');
" 2>&1

echo ""
echo "=== All patches applied. Verifying ==="
docker exec credebl-utility node -e "var c=require('fs').readFileSync('/app/dist/apps/utility/main.js','utf8');process.stdout.write('Patch1: '+(c.includes('PATCH: S3 MinIO')?'OK':'MISSING')+'\n');" 2>/dev/null
docker exec credebl-api-gateway node -e "var c=require('fs').readFileSync('/app/dist/apps/api-gateway/main.js','utf8');process.stdout.write('Patch2: '+(c.includes('require_tld:false')?'OK':'MISSING')+'\n');" 2>/dev/null
docker exec credebl-issuance node -e "var c=require('fs').readFileSync('/app/dist/apps/issuance/main.js','utf8');process.stdout.write('Patch4: '+(c.includes('PATCH: schema URL dedup')?'OK':'MISSING')+' Patch5: '+(c.includes('ctx.map(function(url)')?'OK':'MISSING')+'\n');" 2>/dev/null
docker exec "$CREDO" node -e "var c=require('fs').readFileSync('/app/build/events/CredentialEvents.js','utf8');process.stdout.write('Patch3: '+((c.includes('credentials try-catch guard')||c.includes('getFormatData unavailable'))?'OK':'MISSING')+'\n');" 2>/dev/null
docker exec "$CREDO" node -e "var c=require('fs').readFileSync('/app/build/events/ProofEvents.js','utf8');process.stdout.write('Patch7: '+(c.includes('proofData try-catch guard')?'OK':'MISSING')+'\n');" 2>/dev/null
