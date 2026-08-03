import Foundation

/// Fertige Entwürfe für Winlink-Katalogabfragen und Saildocs-Anfragen.
/// Beides sind gewöhnliche B2F-Nachrichten an Spezialadressen — die
/// Antwort kommt als normale Mail mit dem angeforderten Inhalt zurück.
public enum CatalogRequest {

    /// CMS-interne Adresse für Katalogabfragen.
    public static let inquiryAddress = "INQUIRY"

    /// Saildocs-Dienst: liefert Webseiten als Text und GRIB-Wetterdaten
    /// auf Anfrage per Mail (seit 1995, von Jim Corenman).
    public static let saildocsAddress = "query@saildocs.com"

    /// Katalog-Item mit der Hilfedatei zum Winlink-Katalog.
    public static let helpItem = "WL2K_HELP"

    /// Abfrage von Katalog-Items beim CMS: Message an INQUIRY, Subject
    /// `REQUEST`, ein Item-Name pro Zeile im Body.
    public static func winlinkInquiry(items: [String]) -> MessageDraft {
        MessageDraft(
            to: [inquiryAddress],
            subject: "REQUEST",
            body: items.joined(separator: "\n"))
    }

    /// Saildocs-Abruf beliebiger Web-Dokumente als Text: eine
    /// `send <URL>`-Zeile pro Dokument. Saildocs ignoriert das Subject;
    /// B2F verlangt aber eines.
    public static func saildocsFetch(urls: [String]) -> MessageDraft {
        MessageDraft(
            to: [saildocsAddress],
            subject: "Saildocs request",
            body: urls.map { "send \($0)" }.joined(separator: "\n"))
    }

    /// Saildocs-GRIB-Anfrage mit roher Spezifikation, z. B.
    /// `GFS:50N,42N,5W,20E|0.5,0.5|0,24,48,72|PRMSL,WIND`.
    public static func saildocsGRIB(_ spec: String) -> MessageDraft {
        MessageDraft(
            to: [saildocsAddress],
            subject: "Saildocs request",
            body: "send \(spec)")
    }
}
