# PostgreSQL Failover Demo

Ez egy Docker Compose alapú PostgreSQL failover demó két adatbázis konténerrel és egy egyszerű Python writer alkalmazással.


## Előfeltételek

- Docker
- Bash
- Python + psql a host gépen a downtime lekérdezés futtatásához

## Felépítés

A projektben három fő komponens van:

- `postgres-master` : kezdetben ez az írható primary node
- `postgres-slave` : kezdetben standby node, streaming replicationnel követi a mastert
- `writer` : Python program, ami folyamatosan timestamp rekordokat ír az aktuális primary-ba

A writer nem fixen egy node-ra ír. Először megnézi, melyik PostgreSQL példány írható, majd oda kapcsolódik. Ehhez a `pg_is_in_recovery()`-t használja.

Failoverkor a script leállítja az aktuális primary-t, majd előlépteti a standby-t. Ezután a writer újrapróbálkozik, megtalálja az új írható node-ot, és oda folytatja az írást.

A régi primary később újra standby-ként csatlakozik, így egymás után több failover/failback teszt is futtatható.

## Fontosabb fájlok

- `docker-compose.yml` : konténerek
- `app/writer.py` : timestamp writer
- `scripts/init-replication.sh` : replication inicializálása
- `scripts/failover.sh` : failover futtatása
- `scripts/rejoin-old-master.sh` : régi primary visszacsatlakoztatása standby-ként
- `scripts/run-full-demo-test.sh` : teljes automatikus teszt (elég ezt indítani)
- `scripts/downtime.sql` : kiesési idő becslése timestamp gap alapján

## Tesztelés

Teljes teszt futtatása:

    docker compose down -v --remove-orphans
    ./scripts/run-full-demo-test.sh

! Ez tiszta állapotból indítja a demót, tehát törli a korábbi konténereket és volume-okat !

## Várt eredmény

Sikeres futásnál ez történik:

1. Elindul a `postgres-master` és a `postgres-slave`
2. Beáll a streaming replication
3. A writer elkezd rekordokat írni a masterre
4. A master leáll
5. A slave előlép új primary-vá
6. A writer átvált az új primary-ra
7. A régi master újra standby-ként csatlakozik
8. Lefut egy második failover/failback is
9. A végén a script kiírja a timestamp rekordok alapján becsült downtime-ot

A logokban látszania kell, hogy az írás először a `postgres-master` node-ra megy, failover után a `postgres-slave` node-ra, majd visszaváltás után ismét az aktuális primary-ra.

## Downtime becslés

A writer fix időközönként ír timestamp rekordokat az adatbázisba. (másodpercenként)
A `scripts/downtime.sql` ezek között keresi a normálnál nagyobb időbeli réseket.

Ebből lehet közelítően látni, hogy a writer szempontjából mennyi ideig nem volt elérhető írható adatbázis.

Ez nem pontos monitoring, inkább egy egyszerű mérési módszer a demóhoz.

## Korlátok és fejlesztési lehetőségek

A megoldás egy demó, nem production szintű high availability rendszer. A failover egy scriptből indul, nincs mögötte automatikus leader election vagy consensus réteg, például Patroni + etcd/Consul. A kliensek előtt sincs pl. HAProxy, ezért jelenleg a writer maga keresi meg az aktuális írható primary node-ot.

A Docker stop demó szinten elég a régi primary leállítására, de valódi hálózati hiba esetén nem véd teljesen split-brain ellen.
A synchronous replication csökkenti az adatvesztés esélyét, de önmagában nem jelent minden helyzetben garantált zero data loss működést.

## Hogyan lehetne jobb a downtime?

A downtime csökkentésére a következő irányok lennének reálisak:

- rövidebb connection timeout és retry delay a writerben
- HAProxyv vagy PgBouncerhasználata kliensoldali keresgélés helyett
- Patroni + etcd/Consul alapú automatikus failover
- rendes, részletesebb health check és monitoring
- `pg_rewind` használata teljes újraépítés helyett
- split-brain elleni valódi fencing
- replication slots és WAL archiving használata
