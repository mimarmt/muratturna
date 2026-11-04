# Loopnote: Ürün Kararları

> Sesli, tekrar eden, "canlı" notlar. Her not belirlenen aralıkta kendini sesli olarak hatırlatır.
> Hedef: App Store'da yayınlanacak kalitede, Apple standartlarına tam uyumlu bir iOS ürünü.

## Ürün

| # | Konu | Karar |
|---|------|-------|
| 1 | Not girişi | Sesli ve yazılı |
| 2 | Tekrar aralığı | Tamamen serbest: dakika / saat / gün / hafta (ör. "10 dk'da bir", "her gün 08:30") |
| 3 | Yanıt verilmezse | Bir kez söyler, sonraki tekrar zamanına kadar susar |
| 4 | Bitiş | Opsiyonel bitiş tarihi veya tekrar sayısı; "Tamamlandı" ile kapatılabilir; kapanan notlar arşive gider |
| 5 | Platform | Yerli iOS uygulaması (iPhone + iPad + Mac + Apple Watch) |
| 6 | Okuma dili / ses | Not dili otomatik algılanır (TR/EN/DE); sistem sesleri + Personal Voice |
| 7 | Sessiz saatler | Varsayılan 23:00 – 07:30; biriken notlar sabah toplu okunur |
| 8 | Bildirim eylemleri | Tamamlandı, Ertele (10 dk / 1 sa / yarın), Tekrar dinle; Siri komutları |
| 9 | Gruplama | Renkli projeler/kategoriler; proje bazında topluca susturma |
| 10 | Saklama | SwiftData + iCloud (CloudKit) senkronizasyonu |
| 11 | Kullanıcı | Kişisel kullanım (ekip özelliği yok) |
| 12 | Okunan kısım | Cihaz içi yapay zekâ kısa "sesli başlık" üretir; detay yazılı kalır |
| — | Arayüz dili | İngilizce (ana dil), Türkçe, Almanca; String Catalog ile genişletilebilir |
| 15 | v1.0 kapsamı | Tam paket: tüm teknolojiler ilk sürümde |
| 16 | İsim | **Loopnote** (App Store: "Loopnote – Voice Reminders") |
| 18 | Tasarım yönü | Mimari ve minimal: bol boşluk, ince çizgiler, güçlü tipografi, ışık/gölge vurgusu |
| 19 | Renk ve tipografi | Monokrom + tek vurgu rengi (sıcak amber); başlıklar New York (serif), metin SF Pro; açık/koyu mod sistemi izler |
| 20 | Gelir modeli | Freemium: ücretsiz (10 aktif not, 2 proje) + Loopnote Pro (sınırsız not/proje, kritik notlar, Personal Voice, Watch, widget, Live Activities, iCloud). Fiyat: aylık $2.99, yıllık $19.99 (7 gün deneme), ömür boyu $49.99 |
| 24 | Ses kalitesi | Apple Gelişmiş sesler + ses seçici; Kişisel Ses (yalnızca İngilizce) |
| 25 | Doğal ses | ElevenLabs: test aşamasında kullanıcının kendi API anahtarı (Keychain); yayından önce sunucu proxy + Pro abonelik. Yalnızca sesli başlık gönderilir, ses cihazda saklanır |
| 26 | v1.1 öncelikleri | Sırayla: Toplantı modu → Fotoğraflı not → Konum hatırlatma → AlarmKit |
| 27 | Toplantı başlatma | Ana ekranda Toplantı butonu + Action Button + Kontrol Merkezi + Apple Watch |
| 28 | Toplantı çıktısı | Tam tutanak: özet, kararlar, aksiyonlar (Loopnote hatırlatmasına dönüşür), konuşmacı ayrımlı metin, PDF; WhatsApp/Mail/Kopyala paylaşım |
| 29 | Toplantı yapay zekâ işleme | Apple Private Cloud Compute (iOS 27), yedek cihaz içi parça parça özet; Claude sonradan Pro Plus |
| 21 | Uygulama ikonu | D · Cam Küre: Liquid Glass küre, amber ses dalgası, yayılan halkalar (`design/icons/final/`) |

## Teknoloji

- Swift 6, SwiftUI, Liquid Glass; minimum iOS 26 (iOS 27 özellikleri mevcutsa açılır)
- SwiftData + CloudKit
- Speech (SpeechAnalyzer): cihaz içi yazıya dökme
- Foundation Models: sesli başlık özeti (Apple Intelligence olmayan cihazda kural tabanlı yedek)
- Natural Language: dil algılama
- AVSpeechSynthesizer + Personal Voice: seslendirme, ses dosyasına render
- User Notifications (özel ses ≤ 30 sn), AlarmKit (kritik notlar), Background Tasks (64 bildirim sınırı yönetimi)
- ActivityKit (Live Activities / Dynamic Island), WidgetKit, Controls, Action Button
- App Intents (Siri, Shortcuts, Spotlight entity schemas, View Annotations)
- watchOS uygulaması, Core Haptics
- TipKit, StoreKit 2, MetricKit, Evaluations, AppIntentsTesting, erişilebilirlik

## Derleme ve yayın

- CI/CD: GitHub Actions (macOS runner, Xcode 27) → otomatik TestFlight
- Team ID: `RQ82R94TUH`
- App Store Connect API: Key ID `KTN24G5LBZ` (Admin, "Loopnote CI"), Issuer ID `55f74e1d-057f-4e6b-ac66-a8b5cac5ea0a`
- Özel anahtar yalnızca GitHub Secret olarak: `ASC_KEY_P8`
- Bundle ID: `com.muratturna.loopnote`

## Doğrulanacaklar

- AlarmKit'in özel ses olarak TTS dosyasını çalabilmesi
- AlarmKit kullanımının App Store incelemesine uygunluğu (yalnızca "kritik" notlar)
