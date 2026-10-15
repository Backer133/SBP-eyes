/// Fassung dieser App, sichtbar in der Oberflaeche und im Protokoll.
///
/// Als Konstante, obwohl package_info_plus im Projekt liegt und dasselbe liefern
/// koennte: dessen Abfrage ist asynchron und kann fehlschlagen, und diese Zahl
/// soll gerade dann dastehen, wenn sonst nichts mehr geht. Dass sie zur
/// pubspec.yaml passt, prueft die CI - eine angezeigte Fassung, die luegt, waere
/// schlimmer als gar keine.
///
/// Der Anlass: Im Browser hielt ein Service Worker die alte Fassung vor. Getestet
/// wurde dadurch zeitweise ein Stand von vorgestern, ohne dass es jemand sehen
/// konnte. Der Service Worker ist abgeschaltet - und hier steht, woran man es
/// erkennt.
const String kAppVersion = '3.15.2+50';
