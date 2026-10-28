#include <QTest>
#include <QObject>
#include <QHostAddress>
#include <QRegularExpression>
#include <QTemporaryDir>
#include <QStandardPaths>
#include "../src/SlowrollBackend.h"
#include "../src/DesktopBackend.h"

class DomainTest : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void testSnapperCsvParsingStandard();
    void testSnapperCsvParsingQuotedCommas();
    void testSnapperCsvParsingMissingNumberColumn();
    void testSnapperCsvParsingHashHeader();
    void testMountinfoActiveSnapshotDetection();
    void testNetworkAddressValidation();
    void testNetworkGatewayAndDnsValidation();
    void testEfibootmgrParsing();
    void testToolAvailabilityWithSbin();
    void testDefaultPowerProfile();
    void testNetworkProfilesConfigPath();
    void testCustomActionsCorruptRecovery();
    void testOperationCancellableInitialState();
    void testSystemctlShowBlockParsingOrderIndependent();
    void testRunCommandSanitization();

private:
    QString m_oldHome;
    QString m_oldXdgConfig;
    QTemporaryDir m_tempHome;
};

void DomainTest::initTestCase()
{
    m_oldHome = qEnvironmentVariable("HOME");
    m_oldXdgConfig = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (m_tempHome.isValid()) {
        qputenv("HOME", m_tempHome.path().toLocal8Bit());
        qputenv("XDG_CONFIG_HOME", (m_tempHome.path() + QStringLiteral("/.config")).toLocal8Bit());
    }
}

void DomainTest::cleanupTestCase()
{
    if (!m_oldHome.isEmpty()) {
        qputenv("HOME", m_oldHome.toLocal8Bit());
    }
    if (!m_oldXdgConfig.isEmpty()) {
        qputenv("XDG_CONFIG_HOME", m_oldXdgConfig.toLocal8Bit());
    } else {
        qunsetenv("XDG_CONFIG_HOME");
    }
}

void DomainTest::testSnapperCsvParsingStandard()
{
    SlowrollBackend backend;

    const QString csv = QStringLiteral(
        "config,subvolume,number,default,active,type,pre-number,date,user,used-space,cleanup,description,userdata\n"
        "root,,0,no,no,single,,,,,current,\n"
        "root,,38,no,no,pre,,2026-10-16 18:22:10,root,12345,number,\"zypp(zypper)\",\n"
        "root,,39,yes,yes,post,38,2026-10-16 18:25:30,root,67890,number,\"zypp(zypper)\",\n"
    );

    backend.parseSnapperOutput(csv);

    QCOMPARE(backend.snapshots().size(), 3);

    const QVariantMap snap39 = backend.snapshots().at(2).toMap();
    QCOMPARE(snap39.value(QStringLiteral("number")).toInt(), 39);
    QCOMPARE(snap39.value(QStringLiteral("isDefault")).toBool(), true);
    QCOMPARE(snap39.value(QStringLiteral("isActive")).toBool(), true);
    QCOMPARE(snap39.value(QStringLiteral("type")).toString(), QStringLiteral("post"));
    QCOMPARE(snap39.value(QStringLiteral("description")).toString(), QStringLiteral("zypp(zypper)"));

    const QVariantMap snap38 = backend.snapshots().at(1).toMap();
    QCOMPARE(snap38.value(QStringLiteral("number")).toInt(), 38);
    QCOMPARE(snap38.value(QStringLiteral("isDefault")).toBool(), false);
    QCOMPARE(snap38.value(QStringLiteral("isActive")).toBool(), false);
}

void DomainTest::testSnapperCsvParsingQuotedCommas()
{
    SlowrollBackend backend;

    const QString csv = QStringLiteral(
        "config,subvolume,number,default,active,type,pre-number,date,user,used-space,cleanup,description,userdata\n"
        "root,,40,no,no,single,,2026-10-17 10:00:00,root,1111,,\"snapshot, with extra, commas in description\",\n"
    );

    backend.parseSnapperOutput(csv);

    QCOMPARE(backend.snapshots().size(), 1);
    const QVariantMap snap40 = backend.snapshots().at(0).toMap();
    QCOMPARE(snap40.value(QStringLiteral("number")).toInt(), 40);
    QCOMPARE(snap40.value(QStringLiteral("description")).toString(), QStringLiteral("snapshot, with extra, commas in description"));
}

void DomainTest::testSnapperCsvParsingMissingNumberColumn()
{
    SlowrollBackend backend;

    const QString malformedCsv = QStringLiteral(
        "config,subvolume,date,user,description\n"
        "root,,2026-10-17,root,test\n"
    );

    backend.parseSnapperOutput(malformedCsv);
    QVERIFY(backend.snapshots().isEmpty());
    QVERIFY(backend.lastMessage().contains(QStringLiteral("non riconosciuto")));
}

void DomainTest::testSnapperCsvParsingHashHeader()
{
    SlowrollBackend backend;

    const QString hashCsv = QStringLiteral(
        "#,type,pre #,date,user,cleanup,description,userdata\n"
        "1,single,,2026-10-10,root,,baseline snapshot,\n"
    );

    backend.parseSnapperOutput(hashCsv);

    QCOMPARE(backend.snapshots().size(), 1);
    const QVariantMap snap1 = backend.snapshots().at(0).toMap();
    QCOMPARE(snap1.value(QStringLiteral("number")).toInt(), 1);
    QCOMPARE(snap1.value(QStringLiteral("description")).toString(), QStringLiteral("baseline snapshot"));
}

void DomainTest::testMountinfoActiveSnapshotDetection()
{
    const QString sampleMountinfo = QStringLiteral(
        "40 44 0:7 / /dev rw,nosuid shared:2 - devtmpfs devtmpfs rw,size=10029500k,mode=755\n"
        "44 1 0:39 /0/.snapshots/39/snapshot / rw,noatime shared:1 - btrfs /dev/nvme0n1p9 rw,ssd,subvol=/0/.snapshots/39/snapshot\n"
        "42 44 259:11 / /home rw,relatime shared:45 - ext4 /dev/nvme0n1p11 rw\n"
    );

    int active = SlowrollBackend::parseActiveSnapshotFromMountinfo(sampleMountinfo);
    QCOMPARE(active, 39);

    const QString multipleMountinfo = QStringLiteral(
        "40 1 0:39 /0/.snapshots/39/snapshot / rw,noatime shared:1 - btrfs /dev/nvme0n1p9 rw,ssd,subvol=/0/.snapshots/39/snapshot\n"
        "44 1 0:42 /0/.snapshots/42/snapshot / rw,noatime shared:1 - btrfs /dev/nvme0n1p9 rw,ssd,subvol=/0/.snapshots/42/snapshot\n"
    );
    int lastActive = SlowrollBackend::parseActiveSnapshotFromMountinfo(multipleMountinfo);
    QCOMPARE(lastActive, 42);

    const QString nonBtrfsMountinfo = QStringLiteral(
        "44 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"
    );
    int nonBtrfs = SlowrollBackend::parseActiveSnapshotFromMountinfo(nonBtrfsMountinfo);
    QCOMPARE(nonBtrfs, -1);
}

void DomainTest::testNetworkAddressValidation()
{
    QString cleanCidr;
    QVERIFY(DesktopBackend::validateIpv4Cidr(QStringLiteral("192.168.1.100/24"), &cleanCidr));
    QCOMPARE(cleanCidr, QStringLiteral("192.168.1.100/24"));

    QVERIFY(DesktopBackend::validateIpv4Cidr(QStringLiteral("10.0.0.1/8"), &cleanCidr));
    QCOMPARE(cleanCidr, QStringLiteral("10.0.0.1/8"));

    QVERIFY(DesktopBackend::validateIpv4Cidr(QStringLiteral("172.16.0.5"), &cleanCidr)); // Default /24
    QCOMPARE(cleanCidr, QStringLiteral("172.16.0.5/24"));

    QVERIFY(!DesktopBackend::validateIpv4Cidr(QStringLiteral("999.168.1.100/24"))); // Invalid IP octet
    QVERIFY(!DesktopBackend::validateIpv4Cidr(QStringLiteral("192.168.1.100/33"))); // Invalid prefix > 32
    QVERIFY(!DesktopBackend::validateIpv4Cidr(QStringLiteral("192.168.1.100/0")));  // Invalid prefix < 1
    QVERIFY(!DesktopBackend::validateIpv4Cidr(QStringLiteral("2001:db8::1/64")));  // IPv6 rejected for IPv4 profile
    QVERIFY(!DesktopBackend::validateIpv4Cidr(QStringLiteral("not-an-ip")));
}

void DomainTest::testNetworkGatewayAndDnsValidation()
{
    QVERIFY(DesktopBackend::validateGateway(QStringLiteral("192.168.1.1")));
    QVERIFY(!DesktopBackend::validateGateway(QStringLiteral("192.168.1.300")));
    QVERIFY(!DesktopBackend::validateGateway(QStringLiteral("abc.def")));

    QStringList servers;
    QVERIFY(DesktopBackend::validateDns(QStringLiteral("1.1.1.1 8.8.8.8"), &servers));
    QCOMPARE(servers.size(), 2);
    QCOMPARE(servers.at(0), QStringLiteral("1.1.1.1"));
    QCOMPARE(servers.at(1), QStringLiteral("8.8.8.8"));

    QVERIFY(DesktopBackend::validateDns(QStringLiteral("1.1.1.1, 8.8.8.8; 9.9.9.9"), &servers));
    QCOMPARE(servers.size(), 3);

    QVERIFY(!DesktopBackend::validateDns(QStringLiteral("1.1.1.1 invalid-dns")));
    QVERIFY(!DesktopBackend::validateDns(QStringLiteral("2620:fe::fe")));
    QVERIFY(!DesktopBackend::validateDns(QStringLiteral("")));
}

void DomainTest::testEfibootmgrParsing()
{
    const QString sample = QStringLiteral(
        "BootCurrent: 0002\n"
        "Timeout: 1 seconds\n"
        "BootOrder: 0002,0001,0000\n"
        "Boot0000* Fedora\tHD(3,GPT,3f3d34b3,0x2c1800,0x148800)/File(\\EFI\\FEDORA\\SHIMX64.EFI)\n"
        "Boot0001* mySlowrollOS\tHD(1,GPT,208eb1e6,0x800,0x1f9000)/File(\\EFI\\systemd\\systemd-bootx64.efi)\n"
        "Boot0002* openSUSE Boot Manager (systemd-boot)\tHD(1,GPT,208eb1e6,0x800,0x1f9000)/File(\\EFI\\SYSTEMD\\SHIM.EFI)\n"
    );

    QString currentCode, nextCode, currentLabel, nextLabel;
    QVariantList list = SlowrollBackend::parseUefiEntries(sample, currentCode, nextCode, currentLabel, nextLabel);

    QCOMPARE(currentCode, QStringLiteral("0002"));
    QCOMPARE(currentLabel, QStringLiteral("openSUSE Boot Manager (systemd-boot)"));
    QCOMPARE(nextCode, QStringLiteral(""));
    QCOMPARE(list.size(), 3);

    // Boot order is 0002, 0001, 0000
    QCOMPARE(list.at(0).toMap().value("code").toString(), QStringLiteral("0002"));
    QCOMPARE(list.at(0).toMap().value("name").toString(), QStringLiteral("openSUSE Boot Manager (systemd-boot)"));
    QCOMPARE(list.at(0).toMap().value("isCurrent").toBool(), true);
    QCOMPARE(list.at(0).toMap().value("isNext").toBool(), false);

    QCOMPARE(list.at(1).toMap().value("code").toString(), QStringLiteral("0001"));
    QCOMPARE(list.at(1).toMap().value("name").toString(), QStringLiteral("mySlowrollOS"));

    // Test with BootNext set
    const QString sampleWithNext = QStringLiteral(
        "BootCurrent: 0002\n"
        "BootNext: 0001\n"
        "BootOrder: 0002,0001\n"
        "Boot0001* mySlowrollOS\tHD(1,GPT)\n"
        "Boot0002* openSUSE\tHD(2,GPT)\n"
    );
    list = SlowrollBackend::parseUefiEntries(sampleWithNext, currentCode, nextCode, currentLabel, nextLabel);
    QCOMPARE(nextCode, QStringLiteral("0001"));
    QCOMPARE(nextLabel, QStringLiteral("mySlowrollOS"));
    QCOMPARE(list.at(0).toMap().value("isNext").toBool(), false);
    QCOMPARE(list.at(1).toMap().value("isNext").toBool(), true);
}

void DomainTest::testToolAvailabilityWithSbin()
{
    if (!QFile::exists(QStringLiteral("/sbin/yast2")) && !QFile::exists(QStringLiteral("/usr/sbin/yast2"))) {
        QSKIP("yast2 non è presente su questo ambiente di test.");
    }
    DesktopBackend backend;
    QVERIFY(backend.isToolAvailable(QStringLiteral("yast")));
    QVERIFY(backend.isToolAvailable(QStringLiteral("yast-software")));
}

void DomainTest::testDefaultPowerProfile()
{
    DesktopBackend backend;
    QCOMPARE(backend.powerProfile(), QStringLiteral("standard"));
}

void DomainTest::testNetworkProfilesConfigPath()
{
    DesktopBackend backend;
    const QString path = backend.networkProfilesFilePath();
    const QString expectedBase = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    QVERIFY(path.startsWith(expectedBase));
    QVERIFY(path.endsWith(QStringLiteral("myslowroll-cc/network-profiles.json")));

    QDir().mkpath(QFileInfo(path).absolutePath());
    const QString bakPath = path + QStringLiteral(".bak");
    QFile::remove(path);
    QFile::remove(bakPath);

    QFile f1(path);
    QVERIFY(f1.open(QIODevice::WriteOnly));
    f1.write("{ PRIMA corruzione ");
    f1.close();

    DesktopBackend b1;
    QVERIFY(QFile::exists(bakPath));
    QFile bakFile(bakPath);
    QVERIFY(bakFile.open(QIODevice::ReadOnly));
    const QByteArray firstBakContent = bakFile.readAll();
    bakFile.close();
    QVERIFY(firstBakContent.contains("PRIMA corruzione"));

    QFile f2(path);
    QVERIFY(f2.open(QIODevice::WriteOnly));
    f2.write("{ SECONDA corruzione ");
    f2.close();

    DesktopBackend b2;
    QVERIFY(bakFile.open(QIODevice::ReadOnly));
    const QByteArray secondBakContent = bakFile.readAll();
    bakFile.close();
    QCOMPARE(secondBakContent, firstBakContent);
}

void DomainTest::testCustomActionsCorruptRecovery()
{
    DesktopBackend backend;
    const QString path = backend.customActionsFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    QVERIFY(f.open(QIODevice::WriteOnly));
    f.write("{ invalid json ");
    f.close();

    backend.reloadCustomActions();
    QVERIFY(backend.customActions().isEmpty());
    QVERIFY(!backend.saveCustomAction(QString(), QStringLiteral("test"), QStringLiteral("echo 1"), false));

    QVERIFY(backend.resetCustomActionsToDefault());
    QVERIFY(backend.saveCustomAction(QString(), QStringLiteral("valid"), QStringLiteral("echo 2"), false));
    QCOMPARE(backend.customActions().size(), 1);
}

void DomainTest::testOperationCancellableInitialState()
{
    SlowrollBackend slowrollBackend;
    DesktopBackend desktopBackend;
    QCOMPARE(slowrollBackend.isOperationCancellable(), false);
    QCOMPARE(desktopBackend.isOperationCancellable(), false);
}

void DomainTest::testSystemctlShowBlockParsingOrderIndependent()
{
    const QString fakeOutput = QStringLiteral(
        "ActiveState=active\n"
        "Id=firewalld.service\n"
        "LoadState=loaded\n"
        "\n\n"
        "Id=NetworkManager.service\n"
        "ActiveState=active\n"
        "LoadState=loaded\n"
        "\n\n"
        "LoadState=loaded\n"
        "ActiveState=failed\n"
        "Id=cups.service\n"
    );

    const QVariantMap map = SlowrollBackend::parseSystemctlShowOutput(fakeOutput);

    QCOMPARE(map.value(QStringLiteral("firewalld.service")).toString(), QStringLiteral("active"));
    QCOMPARE(map.value(QStringLiteral("NetworkManager.service")).toString(), QStringLiteral("active"));
    QCOMPARE(map.value(QStringLiteral("cups.service")).toString(), QStringLiteral("failed"));
}

void DomainTest::testRunCommandSanitization()
{
    DesktopBackend backend;
    // Unauthorized binary
    backend.runCommand(QStringLiteral("cat /etc/passwd"), QStringLiteral("Test"));
    QVERIFY(backend.lastMessage().contains(QStringLiteral("non autorizzato")));

    // Disallowed character: semicolon
    backend.runCommand(QStringLiteral("glxinfo ; rm -rf /"), QStringLiteral("Test"));
    QVERIFY(backend.lastMessage().contains(QStringLiteral("non consentiti")));

    // Disallowed character: subshell
    backend.runCommand(QStringLiteral("glxinfo $(id)"), QStringLiteral("Test"));
    QVERIFY(backend.lastMessage().contains(QStringLiteral("non consentiti")));

    // Disallowed pipe filter (sort -o)
    backend.runCommand(QStringLiteral("journalctl | sort -o /tmp/evil"), QStringLiteral("Test"));
    QVERIFY(backend.lastMessage().contains(QStringLiteral("pipe consentita solo verso comandi di filtro")));
}

QTEST_MAIN(DomainTest)
#include "test_domain.moc"
