# BStoeq geliştirme kılavuzu

## Çalışma ortamı

Güncel kaynak kodu ve medya araçlarını kurmak için proje klasöründe `./scripts/install.sh` çalıştır. `./scripts/install.sh --release` ise GitHub’daki hazır sürümü indirir, beklenen SHA-256 değerini denetler ve tam Xcode kurulumu olmadan yükler. Geliştirme ve test için Apple Silicon üzerinde macOS 27 veya üstü ve Swift 6 ile macOS 27 SDK’sını içeren tam Xcode kurulumu gerekir. SwiftUI görünümleri Xcode ile gelen makro eklentilerini kullanır. Proje kökünden SwiftPM komutlarını çalıştırabilirsin. [GitHub’dan kurulum](README.tr.md#githubdan-kurulum)

```sh
swift build
swift test
```

Menü çubuğundaki davranışı denemek için aşağıdaki paketleme komutunu çalıştır. `dist/BStoeq-macOS.zip` içindeki uygulamayı **Uygulamalar** klasörüne kur ve oradan aç. Paketleme betiği derlenmiş arşiv motorunu, çalışma zamanında kullanılan kaynak paketlerini, çevirileri ve lisansları uygulamaya ekler. [Kurulum ve ilk açılış](README.tr.md#githubdan-kurulum)

## Kaynak düzeni

- `Sources/BStoeq` menü çubuğu uygulamasını, ayarları ve kullanıcı işlemlerini yönetir.
- `Sources/BStoeqCore` disk, temizlik ve kopya dosya taramalarını, uygulama kaldırmayı, indirme seçeneklerini ve ortak modelleri içerir.
- `Sources/BStoeqRuntime` ve `Sources/MenuBarBridge` menü çubuğuyla sistem düzeyindeki etkileşimi sağlar.
- `Sources/ArchiveCore` arşiv biçimlerini, 7-Zip süreçlerini ve dosya işlemlerini yönetir. `Sources/ArchiveWorkspace` arşiv penceresini ve dosya gezginini içerir.
- `Tests` birim ve regresyon testlerini barındırır. `Resources` paket bilgilerini, araçları ve lisans metinlerini içerir.
- `BStoeq Kur.command`, Finder’dan hazır sürüm kurulumunu başlatır. `scripts/install.sh` kurulum türüne göre gereken bağımlılıkları sağlar. `scripts/install-app.sh` uygulama kimliğini ve imzasını denetleyip paketi Uygulamalar klasörüne taşır.
- `scripts/build.sh` dağıtım paketini oluşturur ve `scripts/icon.swift` simgelerini üretir. Elle test için `scripts/TestFixture.swift` geçici bir menü çubuğu simgesi oluşturur. `scripts/engine-probe.m` menü çubuğu sistem arayüzünün etkinleştirilip serbest bırakılabildiğini denetler.

## Değişiklikleri doğrulama

SwiftPM filtresiyle yalnızca değiştirdiğin alanın testlerini çalıştırabilirsin. Aşağıdaki iki komut temizlikte uygulama seçimini ve arşiv işlemlerini sınar.

```sh
swift test --filter UnusedAppsTests
swift test --filter ArchiveCoreTests
```

Dosya taşıma, çıkartma veya temizleme davranışlarını test ederken geçici bir klasörde deneme verileri oluştur. Mevcut testler temizleme işlemlerinde geçici bir Çöp Sepeti kullanır. Yeni bir arayüz metni eklersen ilgili dil kaynağına Türkçe, İngilizce ve Almanca karşılıklarını ekle. Bir değişikliği paylaşırken hangi kullanım senaryosunu etkilediğini, nasıl tekrarlanabildiğini ve hangi kontrolleri çalıştırdığını belirt.

## Paketleme ve imzalama

Aşağıdaki komut bir Release derlemesi alır, paketi yerel (*ad hoc*) imzayla imzalar ve ZIP dosyasını `dist/` klasörüne yazar. Ayrı bir çıktı klasörü seçmek için `BSTOEQ_OUTPUT_DIR` ayarlanabilir.

```sh
BSTOEQ_SIGNING_IDENTITY=- ./scripts/build.sh
```

Kendi sertifikanı kullanmak için `BSTOEQ_SIGNING_IDENTITY` değerini imza kimliğin olarak ayarla. Varsayılan ayarlarda betik, Anahtar Zinciri’nde tek bir uygun Apple Development kimliği bulursa o kimliği kullanır. Geliştirici sertifikasıyla imzalanan uygulamanın imza bilgilerinde sertifika sahibi görünür. Apple’ın noter onayı ayrı bir dağıtım adımıdır.

Üçüncü taraf motoru değiştirirken çalıştırılabilir dosyayı, karşılık gelen kaynak arşivini, lisans metinlerini ve doğrulama özetlerini birlikte güncelle. Bileşenlerin konumları üçüncü taraf bildirimlerinde bulunur. [Üçüncü taraf bildirimleri](THIRD_PARTY_NOTICES.md)
