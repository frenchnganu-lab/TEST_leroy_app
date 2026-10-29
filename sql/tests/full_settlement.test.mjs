import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE cabinet_reader; CREATE ROLE make_connector;
CREATE SCHEMA leroy_private;
CREATE TABLE designers(designer_id text PRIMARY KEY,telegram_id bigint,is_active boolean);
CREATE TABLE projects(project_id bigint PRIMARY KEY,order_number text,designer_id text);
CREATE TABLE designer_activities(activity_id bigint PRIMARY KEY,designer_id text,activity_type text,source_event_id text);
CREATE TABLE ledger_entries(entry_id bigint PRIMARY KEY,operation_key text UNIQUE,designer_id text,project_id bigint,operation_type text,currency text,amount numeric);
INSERT INTO designers VALUES ('D001',1,true),('TG-aBc',2,true),('D003',3,true);
INSERT INTO projects VALUES (1,'ORDER-1','D001'),(2,'ORDER-2','TG-aBc'),(3,'ORDER-3','TG-aBc');
INSERT INTO designer_activities VALUES (1,'TG-aBc','mention_bonus','MENTION-ABC'),(2,'TG-aBc','event_bonus','EVENT-1');
INSERT INTO ledger_entries VALUES
(1,'TEST|PROJECT|1|project_share','D001',1,'project_share','RUB',5000),
(2,'TEST|PROJECT|1|project_bonus','D001',1,'project_bonus','LR',25000),
(3,'TEST|ACTIVITY|1','TG-aBc',NULL,'mention_bonus','LR',10000),
(4,'TEST|ACTIVITY|2','TG-aBc',NULL,'event_bonus','LR',10000),
(5,'TEST|REFERRAL|TG-aBc','D001',2,'referral_bonus','LR',50000),
(6,'TEST|PROJECT|2|project_share','TG-aBc',2,'project_share','RUB',7000);`);
const sql=fs.readFileSync(new URL('../08_full_operation_settlement.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql);
let checks=0;
const pay='SELECT * FROM public.settle_sheet_operation($1,$2,$3,$4,$5,$6)';
async function fails(args){await assert.rejects(db.query(pay,args));checks++;}
await fails(['','D001','доля от проекта','ORDER-1',null,5000]);
await fails(['row1','D003','доля от проекта','ORDER-1',null,5000]);
await fails(['row1','D001','доля от проекта','ORDER-1',null,2000]);
await fails(['row1','D001','доля от проекта','MISSING',null,5000]);
await fails(['row1','D001','доля от проекта','ORDER-1',null,'NaN']);
const a=(await db.query(pay,['row1','d001','доля от проекта','order-1',null,5000])).rows[0];
assert.equal(a.already_settled,false);checks++;
const b=(await db.query(pay,['row1','D001','доля от проекта','ORDER-1',null,5000])).rows[0];
assert.equal(b.already_settled,true);checks++;
assert.equal(a.settled_at.getTime(),b.settled_at.getTime());checks++;
await fails(['another','D001','доля от проекта','ORDER-1',null,5000]);
await fails(['row1','TG-aBc','доля от проекта','ORDER-2',null,7000]);
await fails(['row2','D001','бонус за закрытый проект','ORDER-1',null,5000]);
await db.query(pay,['row2','D001','бонус за закрытый проект','ORDER-1',null,25000]);checks++;
await db.query(pay,['row3','TG-aBc','бонус за метки',null,'mention-abc',10000]);checks++;
await fails(['row4','TG-ABC','бонус за мероприятия',null,'EVENT-1',10000]);
await db.query(pay,['row4','TG-aBc','бонус за мероприятия',null,'event-1',10000]);checks++;
await fails(['row5','D003','бонус за реферала','ORDER-2',null,50000]);
await fails(['row5','D001','бонус за реферала','ORDER-3',null,50000]);
await db.query(pay,['row5','D001','бонус за реферала','ORDER-2',null,50000]);checks++;
const bal=(await db.query('SELECT * FROM leroy_private.get_settlement_balance(1)')).rows[0];
assert.equal(Number(bal.commission_accrued_rub),5000);checks++;
assert.equal(Number(bal.commission_paid_rub),5000);checks++;
assert.equal(Number(bal.commission_remaining_rub),0);checks++;
assert.equal(Number(bal.bonus_redeemed_lr),75000);checks++;
assert.equal(Number(bal.bonus_remaining_lr),0);checks++;
assert.equal((await db.query('SELECT * FROM ledger_entries')).rows.length,6);checks++;
await assert.rejects(db.exec('UPDATE ledger_entries SET amount=1 WHERE entry_id=1'));checks++;
await db.exec('SET ROLE cabinet_reader');await fails(['x','TG-aBc','доля от проекта','ORDER-2',null,7000]);
assert.equal(Number((await db.query('SELECT * FROM leroy_private.get_settlement_balance(2)')).rows[0].commission_remaining_rub),7000);checks++;
await db.exec('RESET ROLE; SET ROLE make_connector');
assert.equal((await db.query(pay,['row1','D001','доля от проекта','ORDER-1',null,5000])).rows[0].already_settled,true);checks++;
await db.close();console.log(`${checks} checks passed; migration applied twice`);
