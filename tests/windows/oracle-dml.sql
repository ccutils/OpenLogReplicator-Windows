whenever sqlerror exit failure rollback
set pages 100 lines 220
insert into OLRW_20261116_7A32.CDC_TEST values (101, 'first', null);
commit;
update OLRW_20261116_7A32.CDC_TEST set VALUE=unistr('\4E2D\6587'), OPTIONAL_VALUE='changed' where ID=101;
commit;
insert into OLRW_20261116_7A32.CDC_TEST values (102, 'retained', null);
commit;
delete from OLRW_20261116_7A32.CDC_TEST where ID=101;
commit;
insert into OLRW_20261116_7A32.CDC_TEST values (103, 'rolled-back', null);
rollback;
select ID, VALUE, OPTIONAL_VALUE from OLRW_20261116_7A32.CDC_TEST order by ID;
exit
