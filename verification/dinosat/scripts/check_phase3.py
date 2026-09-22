#!/usr/bin/env python3
"""Check compiled test references and report generated coverage, not proof results."""
import json, re, hashlib
from pathlib import Path
from collections import Counter, defaultdict
ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'verification/dinosat'
def read(name): return json.loads((OUT/name).read_text())
def write(name, value): (OUT/name).write_text(json.dumps(value, indent=2)+'\n')
obligations=read('proof-obligations.json')
known={p['id']:p for p in obligations}
contracts={}; declarations={}; artifacts=[]
for file in (ROOT/'out-halmos').glob('*/*.json'):
    if file.name.endswith('.metadata.json'): continue
    d=json.loads(file.read_text())
    source=d.get('ast',{}).get('absolutePath','')
    if not source.startswith('test/dinosat/'): continue
    for node in d.get('ast',{}).get('nodes',[]):
        if node.get('nodeType')!='ContractDefinition': continue
        declarations[(source,node['name'])]=node
    targets=d.get('metadata',{}).get('settings',{}).get('compilationTarget',{})
    name=targets.get(source)
    if not name: continue
    abi=[a for a in d.get('abi',[]) if a.get('type')=='function' and a.get('name','').startswith('test_')]
    deployed=bool(d.get('bytecode',{}).get('object','').removeprefix('0x'))
    contracts[name]={'file':source,'tests':{a['name']:a for a in abi},'deployable':deployed}
    if deployed and abi: artifacts.append({'file':source,'contract':name,'check_tests':sum(a['name'].startswith('test_check_') for a in abi),'fuzz_tests':sum(a['name'].startswith('test_fuzz_') for a in abi)})

# Extract root-owned mappings from compiler documentation rather than source regex positions.
core_tests=[]
for (file,contract),node in declarations.items():
    if not file.startswith(('test/dinosat/core/','test/dinosat/integration/')): continue
    source=(ROOT/file).read_text()
    for fn in node.get('nodes',[]):
        if fn.get('nodeType')!='FunctionDefinition' or not fn.get('name','').startswith('test_'): continue
        docs=fn.get('documentation',{}); docs=docs.get('text','') if isinstance(docs,dict) else docs
        ids=[i for i in known if re.search(r'(?<![A-Z0-9-])'+re.escape(i)+r'(?![A-Z0-9-])',docs)]
        line=source[:int(fn['src'].split(':')[0])].count('\n')+1
        core_tests.append({'file':file,'contract':contract,'function':fn['name'],'line':line,'property_ids':ids,'assertions':docs,'mode':'fuzz' if fn['name'].startswith('test_fuzz_') else 'symbolic_candidate','execution_status':'NO_FORMAL_RUN'})
core_properties=[]
core_limits={
'AV3-INIT':['Zero-role and arbitrary token behavior remain deployment assumptions. Decimal differences 0..77 are enumerated.'],
'AV3-ADMIN':['Mock fee vault token behavior and standard share balances.'],
'AV3-CAPACITY':['The main withdrawal oracle uses one account at a fixed share price. Cross-account global lock sequences need broader exploration.'],
'AV3-VALUE':['Zero share price is checked separately. Debt-bearing conversion at zero price may revert and is not claimed live.'],
'AV3-LIQUIDATE':['Insufficient-fee and loss cases are bounded. Arbitrary multi-account histories and all dust combinations are not covered.'],
'AV3-BATCH':['Batch model contains one valid position, duplicates and invalid IDs. Longer mixed-position batches remain open.'],
'AV3-REDEEM':['Direct ratio oracle starts from a full Q128 index. Arbitrary long fractional-redemption histories remain open.'],
'AV3-SURVIVAL':['Finite same/cross-epoch histories. No induction over an unbounded sequence.'],
'AV3-PACKED':['Chronological weight domain is explicit. Maximum packed epoch overflow is not proved.'],
'INT-FLOW':['Standard exact-transfer token fixture. Real Alchemist, VaultV2, position NFT and Transmuter implementations.'],
'INT-COVER':['Claims, donations and repayments use short real graph histories. Arbitrary interleaving with liquidation remains open.'],
'INT-LOSS':['The real vault loss fixture uses one loss magnitude. Gain, fee accrual and zero-value paths are not exhaustive.'],
'INT-SUPPLY':['External token mint/burn models supply changes; it is not a bridge implementation proof.'],
'INT-ROUTER':['Actual contract round trips and claims. Hostile callback coverage uses the separate router unit fixtures.'],
'INT-CAPS':['Refer to governance production strategy composition. Limited strategies, cap values and transaction histories.']}
for p in obligations:
    if p['group'] not in ('core','integration'): continue
    tests=[t for t in core_tests if p['id'] in t['property_ids']]
    core_properties.append({'property_id':p['id'],'priority':p['priority'],'tests':tests,'status':'GENERATED_NOT_FORMALLY_EXECUTED','remaining_gaps':core_limits.get(p['id'],['Finite fixtures and input bounds only. No unbounded whole-protocol safety claim.'])})
write('core-integration-test-map.json',{'status':'GENERATED','properties':core_properties,'tests':core_tests,'fixtures':['Actual Alchemist logic behind ERC1967Proxy. Unit token/vault/graph fixtures have explicit limitations.','IntegrationVault inherits VaultV2 without changing public algorithms. beginTransaction clears only the transaction cache between modeled transactions.','Private slot readers are checked against compiler storageLayout.']})

maps=['core-integration-test-map.json','governance-test-map.json','strategy-test-map.json','library-transmuter-test-map.json']
merged={i:{'id':i,'priority':p['priority'],'group':p['group'],'tests':[],'limits':[]} for i,p in known.items()}
errors=[]
for name in maps:
    data=read(name)
    for p in data['properties']:
        key=p.get('property_id',p.get('id'))
        if key not in merged: errors.append('Unknown property '+str(key)); continue
        merged[key]['tests'].extend(p.get('tests',[]))
        for field in ['remaining_gaps','subclaim_gaps','unimplemented_subclaims','assumptions']:
            merged[key]['limits'].extend(p.get(field,[]))
    aliases=data.get('integration_aliases',{})
    if isinstance(aliases,dict):
        for key,values in aliases.items():
            if key not in merged:continue
            if isinstance(values,list):merged[key]['tests'].extend(values)
# Also use compiler docs to pick up integration aliases and abstract fee-vault aliases from other scopes.
for (file,contract),node in declarations.items():
    for fn in node.get('nodes',[]):
        if fn.get('nodeType')!='FunctionDefinition' or not fn.get('name','').startswith('test_'):continue
        docs=fn.get('documentation',{}); docs=docs.get('text','') if isinstance(docs,dict) else docs
        for key in ('INT-CAPS','STR-FEE-ABSTRACT-WITHDRAW','STR-FEE-ABSTRACT-TOTAL'):
            if key in docs:merged[key]['tests'].append({'file':file,'contract':contract,'function':fn['name']})
for key,p in merged.items():
    valid=[];seen=set()
    for t in p['tests']:
        if not isinstance(t,dict): errors.append(f'Invalid test record for {key}: {t}'); continue
        c=t.get('contract');fn=t.get('function');file=t.get('file')
        if not c or not fn:errors.append(f'Incomplete test record for {key}: {t}');continue
        if c not in contracts or fn not in contracts[c]['tests']:
            errors.append(f'Missing compiled reference {key} {c}.{fn}');continue
        execution=t.get('execution_contracts') or ([c] if contracts[c]['deployable'] else [])
        for target in execution:
            if target not in contracts or fn not in contracts[target]['tests'] or not contracts[target]['deployable']:
                errors.append(f'Non-executable reference {key} {target}.{fn}');continue
            ident=(target,fn)
            if ident in seen:continue
            seen.add(ident);valid.append({'contract':target,'function':fn,'file':contracts[target]['file']})
    p['tests']=valid
    p['test_count']=len(valid)
    p['status']='ASSOCIATED_WITH_COMPILED_TESTS' if valid else 'NO_EXECUTABLE_TEST'
    p['limits']=list(dict.fromkeys(p['limits']))
missing=[p['id'] for p in merged.values() if not p['tests']]
p0=[i for i in missing if known[i]['priority']=='P0']
oversized=[a for a in artifacts if a['check_tests']>30]
if oversized:errors.append('Contracts exceed 30 checks: '+str(oversized))
if p0:errors.append('P0 groups with zero tests: '+str(p0))

layout=json.loads((ROOT/'out-halmos/CoreFixture.sol/CoreAlchemistHarness.json').read_text())['storageLayout']
actual={x['label']:int(x['slot']) for x in layout['storage']}
expected={'_totalRedeemedDebt':26,'_totalRedeemedSharesOut':27,'_earmarkWeight':28,'_redemptionWeight':29,'_survivalAccumulator':30,'_mytSharesDeposited':31,'_pendingCoverShares':32,'_accounts':33}
if any(actual.get(k)!=v for k,v in expected.items()):errors.append('Core storage reader layout mismatch')
source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'test/dinosat').rglob('*.sol'))}
summary={'property_groups':len(merged),'groups_with_tests':len(merged)-len(missing),'p0_groups_without_tests':p0,'other_groups_without_tests':[i for i in missing if i not in p0],'test_contracts':len(artifacts),'compiled_check_instances':sum(a['check_tests'] for a in artifacts),'compiled_fuzz_instances':sum(a['fuzz_tests'] for a in artifacts),'max_checks_per_contract':max(a['check_tests'] for a in artifacts),'errors':errors,'note':'Association is not statement coverage, proof, or evidence that every test can succeed. Candidate tests are included and may deliberately fail.'}
# Function association covers the planned public/external inventory, not measured code coverage.
function_rows=[]
for scope_name in ['core-scope.json','governance-scope.json','strategies-scope.json','transmuter-libraries-scope.json']:
    for fn in read(scope_name).get('functions',[]):
        signature=fn.get('signature','')
        visibility=fn.get('visibility','')
        if visibility not in ('public','external') and not re.search(r'\b(public|external)\b',signature):continue
        if fn.get('implemented') is False:continue
        ids=fn.get('property_ids',fn.get('properties',[]))
        if not ids:
            source=fn.get('file',fn.get('source','').split(':')[0]); name=fn['name']
            ids=[p['id'] for p in obligations if name in p.get('functions',[]) and any(x.startswith(source+':') for x in p.get('sources',[]))]
        linked=[i for i in ids if i in merged and merged[i]['tests']]
        function_rows.append({'source':fn.get('file',fn.get('source')),'name':fn['name'],'signature':signature,'properties':ids,'groups_with_tests':linked})
function_gaps=[r for r in function_rows if not r['groups_with_tests']]
summary['public_external_inventory_rows']=len(function_rows)
summary['public_external_rows_without_association']=len(function_gaps)
write('phase3-function-coverage.json',{'note':'Functions link to property-group test references. This is not runtime branch or statement coverage. Inherited functions and overloads can have multiple inventory rows.','functions':function_rows,'unassociated':function_gaps})
write('phase3-coverage.json',{'summary':summary,'properties':list(merged.values()),'contracts':artifacts,'source_sha256':source_hashes,'checked_core_storage_slots':expected})
lines=['# Phase 3 test coverage','', 'This table links property groups to compiled test functions. It does not report proofs.','', '| Property | Priority | Tests | Status |','|---|---|---:|---|']
for p in merged.values():lines.append(f"| {p['id']} | {p['priority']} | {p['test_count']} | {p['status']} |")
(OUT/'PHASE3_COVERAGE.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(summary,indent=2))
raise SystemExit(bool(errors))
