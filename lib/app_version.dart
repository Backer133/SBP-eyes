/// Fassung dieser App, sichtbar in der Oberflaeche und im Protokoll.
///
/// Als Konstante und nicht aus dem Paket gelesen: dafuer braeuchte es eine
/// weitere Abhaengigkeit, und die Zahl soll auch dann stimmen, wenn gar nichts
/// anderes mehr geht. Dass sie zur pubspec.yaml passt, prueft die CI - eine
/// angezeigte Fassung, die luegt, waere schlimmer als gar keine.
///
/// Der Anlass: Im Browser hielt ein Service Worker die alte Fassung vor. Getestet
/// wurde dadurch zeitweise ein Stand von vorgestern, ohne dass es jemand sehen
/// konnte. Der Service Worker ist abgeschaltet - und hier steht, woran man es
/// erkennt.
const String kAppVersion = '3.8.1+38';
