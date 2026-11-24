"""Generates realistic sample data: 3 regions, 6 crews, 9 users, 1,200 jobs."""
import random, datetime as dt
random.seed(7)
R = ['North Dallas', 'Fort Worth', 'Austin']
out = ["INSERT INTO core.regions(name) VALUES " + ",".join(f"('{r}')" for r in R) + ";"]
out.append("INSERT INTO core.crews(name, region_id) VALUES ('Crew A',1),('Crew B',1),('Crew C',2),('Crew D',2),('Crew E',3),('Crew F',3);")
users = [('owner@roofco.test','admin',None,None),('claims@roofco.test','claims',None,None),('ops.north@roofco.test','ops_manager',1,None),
         ('ops.fw@roofco.test','ops_manager',2,None),('maria@roofco.test','estimator',1,None),('dev@roofco.test','estimator',2,None),
         ('lead.a@roofco.test','crew_lead',None,1),('lead.c@roofco.test','crew_lead',None,3),('former@roofco.test','estimator',1,None)]
out.append("INSERT INTO core.app_users(email, role, region_id, crew_id) VALUES " + ",".join(
    f"('{e}','{r}',{g or 'NULL'},{c or 'NULL'})" for e, r, g, c in users) + ";")
out.append("UPDATE core.app_users SET active = false WHERE email = 'former@roofco.test';")
first = ['James','Maria','Robert','Linda','Michael','Patricia','David','Jennifer','Carlos','Susan','Daniel','Karen']
last = ['Smith','Garcia','Johnson','Martinez','Brown','Davis','Lopez','Wilson','Anderson','Thomas']
streets = ['Oak Ridge Dr','Cedar Ln','Hillcrest Ave','Preston Rd','Mockingbird Ln','Elm St','Lakeview Blvd']
cust = []
for i in range(1, 801):
    cust.append(f"('{random.choice(first)} {random.choice(last)}','214-555-{random.randint(1000,9999)}','c{i}@mail.test','{random.randint(100,9999)} {random.choice(streets)}')")
out.append("INSERT INTO core.customers(full_name, phone, email, address) VALUES " + ",".join(cust) + ";")
ST = ['lead','inspected','estimated','sold','scheduled','in_progress','complete','lost']
W = [20,12,14,8,10,6,22,8]
est = {1: 'maria@roofco.test', 2: 'dev@roofco.test', 3: 'owner@roofco.test'}
jobs, claims = [], []
base = dt.datetime(2026, 11, 20, 12)
for jid in range(1, 1201):
    reg = random.choice([1, 1, 2, 3]); st = random.choices(ST, W)[0]
    crew = random.choice([2*reg-1, 2*reg]) if st in ('scheduled','in_progress','complete') else None
    sq = round(random.uniform(14, 48), 1); price = round(sq * random.uniform(420, 610), 2)
    ins = random.random() < 0.45
    created = base - dt.timedelta(minutes=random.randint(0, 200*24*60))
    jobs.append(f"({random.randint(1,800)},{reg},{crew or 'NULL'},'{est[reg]}','{st}','{random.choice(['shingle','shingle','shingle','metal','tile','flat'])}',{sq},{price},{str(ins).lower()},'{created.isoformat()}Z')")
    if ins:
        claims.append(f"({jid},'{random.choice(['State Farm','Allstate','USAA','Farmers'])}','CLM-{random.randint(100000,999999)}','POL-{random.randint(10000000,99999999)}','Adjuster {random.randint(1,40)}','2026-{random.randint(3,6):02d}-{random.randint(1,28):02d}')")
out.append("INSERT INTO core.jobs(customer_id, region_id, crew_id, estimator, status, roof_type, squares, contract_usd, insurance_job, created_at) VALUES " + ",".join(jobs) + ";")
out.append("INSERT INTO core.claims(job_id, carrier, claim_number, policy_number, adjuster, storm_date) VALUES " + ",".join(claims) + ";")
print("\n".join(out))
