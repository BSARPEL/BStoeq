# BStoeq

BStoeq 2.0, Apple Silicon üzerinde macOS 27 için geliştirilmiş bir menü çubuğu uygulamasıdır. Menü simgelerini düzenlemek, arşiv açmak veya oluşturmak, diskte yer kaplayan öğeleri incelemek ve YouTube indirmelerini yönetmek için kullanılır. Arayüz Türkçe, İngilizce ve Almancadır.

## Kurulum ve ilk kullanım

Bir dağıtım paketin varsa `BStoeq-macOS.zip` dosyasını aç. **BStoeq.app** dosyasını **Uygulamalar** klasörüne taşı ve oradan başlat. Menü çubuğundaki simge gizleme özelliği uygulamayı `/Applications/BStoeq.app` konumunda arar.

Menü çubuğundaki **BStoeq** simgesine sağ tıklayarak ayarları açabilirsin. Ayarlar penceresini kapattığında uygulama menü çubuğunda çalışmaya devam eder. Arşiv yöneticisini **Ayarlar → Arşivler** bölümünden veya simgenin sağ tık menüsündeki **Arşiv yöneticisini aç…** komutuyla açabilirsin.

### Kaynaktan derleme

Apple Silicon bir Mac, Swift 6 araç zinciri ve macOS 27 SDK’sı gerekir. `Package.swift` dosyasının bulunduğu klasörde testleri çalıştırıp ZIP paketini oluşturabilirsin.

```sh
swift test
./scripts/build.sh
```

Paketleme betiği uygulamayı ve arşiv motorunu imzalar, paket imzasını denetler ve `dist/BStoeq-macOS.zip` üretir. İmza kimliğini `BSTOEQ_SIGNING_IDENTITY` ortam değişkeniyle seçebilirsin. Yerel derlemelerin imzalanması ve kaynak dizinleri katkı kılavuzunda açıklanır. [Katkı kılavuzu](CONTRIBUTING.md)

## Menü çubuğu

**Ayarlar → Menü çubuğu** bölümünde hangi uygulama simgelerinin görünür, gizli veya sürekli gizli kalacağını seç. Gizli öğeleri menü çubuğunda, alt panelde veya aramalı listede açabilirsin. Düzenleyicide simgeleri sürükleyerek gerçek menü çubuğundaki sıralarını değiştirebilirsin. Başka uygulamaların simgelerini taşımak veya panelden gerçek menülerini açmak için macOS’un **Erişilebilirlik** izni gerekir.

## Arşivler

**Arşivler** penceresinde bir arşivi aç veya pencereye sürükle. Dosyaları ada göre ara, önizle, bütünlüğünü test et veya seçtiklerini yeni bir klasöre çıkart. Yeni arşiv oluştururken dosyaları ya da klasörleri seçip biçim ve sıkıştırma düzeyini ayarlayabilirsin.

- Birlikte gelen **7-Zip** motoruyla ZIP, 7z, TAR, TAR.GZ, TAR.BZ2 ve TAR.XZ oluşturulabilir. RAR4 ve RAR5 dosyaları açılabilir ve çıkartılabilir.
- ZIP ve 7z arşivlerinde AES-256 şifreleme ve çok parçalı çıktı desteklenir. Çok parçalı bir arşivi okumak için parçaları aynı klasöre koyup `.001` dosyasını aç.
- Şifresiz, tek parçalı ZIP, 7z ve TAR arşivlerine dosya ekleyebilir, arşiv içindeki dosyaları silebilir veya yeniden adlandırabilirsin. Düzenleme tamamlanınca özgün arşiv `.backup` olarak saklanır.
- RAR oluşturma ve onarma için ayrıca edindiğin `rar` komut satırı aracını arşiv ayarlarında seçebilirsin.

Çıkartma yeni bir klasörde tamamlanır. Dışarıya yazabilecek yollar, çakışan dosya adları ve bağlantı içeren arşivler hata olarak bildirilir. Arşiv penceresinde **⌘O** açar, **⌘N** yeni arşiv oluşturur, **⌘E** çıkartır ve **⌘T** bütünlüğü test eder. Finder’da bir arşive sağ tıklayarak **Servisler** menüsünden açma, çıkartma ve test işlemlerine ulaşabilirsin.

## Disk alanı ve temizlik

**Ayarlar → Disk alanı** altında bir disk, ev klasörü veya seçtiğin bir klasörü tara. Sonuçlar diskte kapladıkları alana göre sıralanır. Klasörlere girerek alanı hangi dosyaların kullandığını görebilirsin.

**Ayarlar → Temizlik** taramayı dosya türüne ve konuma göre yürütür.

- Kullanıcı ve uygulama kapsayıcılarındaki önbellekler, tanınan Chromium ve Electron önbellekleri.
- Arşivlenmiş günlükler, eski tanılama raporları, Xcode ara dosyaları ve npm, pip, Gradle önbelleklerinin desteklenen bölümleri.
- İndirilenler klasöründeki eski `.dmg`, `.pkg`, `.mpkg` ve `.xip` dosyaları.
- `/Applications` ve `~/Applications` içindeki, macOS’un kaydettiği son kullanım tarihi seçilen eşikten eski olan uygulamalar. Varsayılan eşik **180 gün** olup **30** ve **90 gün** de seçilebilir.

Dosyalarda hem son erişimin hem de son değişikliğin üzerinden en az 30 gün geçmiş olmalıdır. Uygulamalarda tarih kaydı eksikse paketi Finder’da inceleyebilirsin. Çalışan uygulamalar, Apple uygulamaları ve yakın zamanda güncellenen paketler taşıma adaylarından çıkarılır.

Tarama sonunda neyin taşınacağını sen seçersin. BStoeq seçilenleri yeniden denetler ve onayladıklarını **Çöp Sepeti’ne** taşır. Uygulama temizliği seçilen `.app` paketini kapsar. Öğeleri sepetten geri alabilirsin. Alan sepet boşaltıldığında açılır. Korumalı klasörlerin ne kadarının taranabildiği, macOS’ta verdiğin dosya erişim izinlerine bağlıdır.

## Video ve müzik indirme

**Ayarlar → İndirmeler** bölümüne bir YouTube videosu veya oynatma listesi bağlantısı yapıştır. Video için çözünürlüğü, ses için MP3 veya M4A biçimini ve kayıt klasörünü seçebilirsin. İndirmeler yerel `yt-dlp` aracını, ses dönüştürme ve akış birleştirme işlemleri `ffmpeg` aracını kullanır. İki araç da Homebrew üzerinden kurulabilir.

```sh
brew install yt-dlp ffmpeg
```

## Proje ve bileşenler

SwiftUI ve AppKit arayüzü, SwiftPM hedefleri ve gömülü arşiv motorunun dağıtım dosyaları bu projede bulunur. Geliştirme ve test adımları ile paketlenen üçüncü taraf bileşenlerin kaynakları ayrı belgelerde açıklanır. [Katkı kılavuzu](CONTRIBUTING.md) · [Üçüncü taraf bildirimleri](THIRD_PARTY_NOTICES.md)
