# BStoeq geliştirme kılavuzu

## Çalışma ortamı

Apple Silicon üzerinde macOS 27, macOS 27 SDK’sı ve Swift 6 araç zinciri gerekir. Xcode’da `Package.swift` dosyasını açabilir veya proje kökünden SwiftPM komutlarını kullanabilirsin.

```sh
swift build
swift test
```

Menü çubuğundaki davranışı kurulu uygulamada denemek için `./scripts/build.sh` çalıştır. `dist/BStoeq-macOS.zip` içindeki uygulamayı **Uygulamalar** klasörüne kur ve menü çubuğu simgesinden aç. Paketleme betiği derlenmiş arşiv motorunu, kaynak paketlerini, çevirileri ve lisansları uygulamaya ekler.

## Kaynak düzeni

- `Sources/BStoeq` menü çubuğu uygulamasını, ayarları ve kullanıcı işlemlerini yönetir.
- `Sources/BStoeqCore` disk ve temizlik taramalarını, indirme seçeneklerini ve ortak modelleri içerir.
- `Sources/BStoeqRuntime` ve `Sources/MenuBarBridge` menü çubuğuyla sistem düzeyindeki etkileşimi sağlar.
- `Sources/ArchiveCore` arşiv biçimlerini, 7-Zip süreçlerini ve dosya işlemlerini yönetir. `Sources/ArchiveWorkspace` arşiv penceresini ve dosya gezginini içerir.
- `Tests` birim ve regresyon testlerini barındırır. `Resources` paket bilgilerini, araçları ve lisans metinlerini, `scripts` ise dağıtım betiğini içerir.

## Değişiklikleri doğrulama

SwiftPM filtresiyle yalnızca değiştirdiğin alanın testlerini çalıştırabilirsin. Aşağıdaki iki komut temizlikte uygulama seçimini ve arşiv işlemlerini sınar.

```sh
swift test --filter UnusedAppsTests
swift test --filter ArchiveCoreTests
```

Dosya taşıma, çıkartma veya temizleme davranışlarını test ederken geçici bir klasörde deneme verileri oluştur. Mevcut testler temizleme işlemlerinde geçici bir Çöp Sepeti kullanır. Yeni bir arayüz metni eklersen ilgili dil kaynağına Türkçe, İngilizce ve Almanca karşılıklarını ekle. Bir değişikliği paylaşırken hangi kullanım senaryosunu etkilediğini, nasıl tekrarlanabildiğini ve hangi kontrolleri çalıştırdığını belirt.

## Paketleme ve imzalama

`./scripts/build.sh` bir Release derlemesi alır. Tek bir uygun Apple Development imza kimliği bulursa onu kullanır. Kimlik seçmek için `BSTOEQ_SIGNING_IDENTITY`, yerel ad-hoc imza için `-` değeri kullanılabilir. Ayrı bir çıktı klasörü seçmek için `BSTOEQ_OUTPUT_DIR` ayarlanabilir.

```sh
BSTOEQ_SIGNING_IDENTITY=- ./scripts/build.sh
```

Üçüncü taraf motoru değiştirirken çalıştırılabilir dosyayı, karşılık gelen kaynak arşivini, lisans metinlerini ve doğrulama özetlerini birlikte güncelle. Bileşenlerin konumları üçüncü taraf bildirimlerinde bulunur. [Üçüncü taraf bildirimleri](THIRD_PARTY_NOTICES.md)
