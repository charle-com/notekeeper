import Foundation
import NotekeeperCore

/// Deux réunions de démonstration (transcripts français, 3 locuteurs dont « Moi », prénoms prononcés),
/// pour le test de fumée du serveur MCP et l'essai du module IA.
enum DemoSeed {

    /// Un tour de parole : index du locuteur (0 = Moi, 1 = Locuteur 2, 2 = Locuteur 3) et texte.
    typealias Turn = (Int, String)

    struct DemoMeeting {
        let title: String
        let startedAt: Date
        let source: String
        let participants: [String]
        let turns: [Turn]
    }

    /// Insère les deux réunions et renvoie leurs identifiants (dans l'ordre : kick-off, logistique).
    @discardableResult
    static func seed(into store: Store) throws -> [UUID] {
        var ids: [UUID] = []
        for demo in [kickoff, logistics] {
            ids.append(try insert(demo, into: store))
        }
        return ids
    }

    private static func insert(_ demo: DemoMeeting, into store: Store) throws -> UUID {
        var meeting = Meeting(title: demo.title, startedAt: demo.startedAt, source: demo.source,
                              participants: demo.participants, status: .ready, language: "fr")
        try store.insert(meeting)
        let speakers = [
            Speaker(meetingID: meeting.id, label: "Moi", isMe: true),
            Speaker(meetingID: meeting.id, label: "Locuteur 2", clusterKey: "A"),
            Speaker(meetingID: meeting.id, label: "Locuteur 3", clusterKey: "B"),
        ]
        for s in speakers { try store.upsert(s) }

        // Durée de chaque tour : environ 2,6 mots par seconde, plus une respiration de 0,8 s.
        var clock: TimeInterval = 2
        var segments: [TranscriptSegment] = []
        for (who, text) in demo.turns {
            let words = Double(text.split(separator: " ").count)
            let duration = max(1.5, words / 2.6)
            let speaker = speakers[who]
            segments.append(TranscriptSegment(meetingID: meeting.id, track: speaker.isMe ? .mic : .system,
                                              start: clock, end: clock + duration, text: text,
                                              speakerID: speaker.id, isFinal: true))
            clock += duration + 0.8
        }
        try store.insert(segments)
        meeting.endedAt = demo.startedAt.addingTimeInterval(clock + 5)
        try store.update(meeting)
        return meeting.id
    }

    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso) ?? Date()
    }

    // MARK: - Réunion 1 : kick-off refonte de site (Moi, Priya, Paul)

    static let kickoff = DemoMeeting(
        title: "Kick-off refonte site Atelier Morin",
        startedAt: date("2026-09-03T10:00:00+02:00"),
        source: "Google Meet",
        participants: ["Priya Sharma", "Paul Lemaire"],
        turns: [
            (0, "Bonjour à tous, on est au complet ? Priya, Paul, vous m'entendez bien ?"),
            (1, "Oui, je t'entends très bien. Bonjour Charles."),
            (2, "Salut, c'est bon pour moi aussi, je suis sur le bon micro cette fois."),
            (0, "Parfait. L'objectif ce matin, c'est de cadrer la refonte du site de l'Atelier Morin : périmètre, planning et budget. Priya, tu nous refais le contexte ?"),
            (1, "Bien sûr. L'Atelier Morin vend des meubles sur mesure. Le site actuel date de 2019, il est sous WordPress avec un thème acheté qui n'est plus maintenu. Ils ont trois problèmes : le site est lent sur mobile, les demandes de devis se perdent dans un formulaire qui envoie un mail à une boîte que personne ne lit, et le catalogue n'est pas à jour."),
            (0, "Merci Priya. Sur la lenteur, on a des chiffres ?"),
            (2, "Oui, j'ai lancé un test hier. Le LCP est à quatre secondes et demie sur mobile, principalement à cause des images non compressées et d'un slider qui charge douze photos en haute définition dès l'accueil."),
            (0, "Quatre secondes et demie, c'est violent. Et côté serveur ?"),
            (2, "Le TTFB est correct, autour de six cents millisecondes. C'est un hébergement mutualisé chez o2switch mais ça tient. Le vrai sujet, c'est le front."),
            (1, "Ce qui rejoint ce que le client dit : il n'a pas envie de changer d'hébergeur, il est content du support."),
            (0, "OK, on garde o2switch. Paul, ta reco sur la stack ?"),
            (2, "Je propose de rester sur WordPress mais avec un thème sur mesure, léger, sans page builder. On refait les templates en Gutenberg natif, on passe toutes les images en WebP avec des tailles responsive, et on supprime le slider."),
            (1, "Le client tient à son slider, il l'a dit deux fois en rendez-vous."),
            (2, "On peut garder une image hero avec un visuel fort, et proposer une galerie plus bas dans la page. Mais douze photos en haute définition au-dessus de la ligne de flottaison, non, je ne le ferai pas."),
            (0, "Je suis d'accord avec Paul. Priya, tu porteras ça au client avec les chiffres de performance comme argument, ça passera mieux qu'un avis de goût."),
            (1, "Ça marche, je prépare une page de comparaison avant après pour le prochain rendez-vous."),
            (0, "Deuxième sujet, le formulaire de devis. Aujourd'hui ça part sur contact arobase atelier-morin point fr et personne ne lit."),
            (1, "Exactement. Ils ont perdu au moins trois demandes le mois dernier, dont une cuisine complète. Le patron l'a appris par un client qui a rappelé."),
            (0, "Donc il faut un vrai suivi. Paul, on branche quoi ?"),
            (2, "Le plus simple : un formulaire avec Gravity Forms, une notification vers deux adresses, et une entrée dans un Google Sheet partagé avec un statut. Pas besoin d'un CRM pour une entreprise de six personnes."),
            (1, "Ils ont déjà un abonnement Google Workspace, le Sheet est cohérent."),
            (0, "Validé : formulaire plus double notification plus Google Sheet. On note que le patron reçoit une copie de chaque demande. Ça répond au problème qui a déclenché tout le projet."),
            (2, "Je note. Il faudra aussi un accusé de réception automatique au client final, ils n'en ont pas aujourd'hui."),
            (0, "Bonne idée, ajoute-le. Troisième point, le catalogue. Priya, ils ont combien de produits ?"),
            (1, "Une quarantaine de modèles, répartis en cinq gammes : tables, chaises, bibliothèques, cuisines et dressings. Mais tout est sur mesure, donc pas de prix affiché, uniquement un prix à partir de."),
            (0, "On est sur un site vitrine avec demande de devis, pas un e-commerce. Pas de panier."),
            (1, "Confirmé, le patron ne veut pas vendre en ligne. Il veut que les gens l'appellent."),
            (2, "Alors on fait un type de contenu personnalisé Réalisation avec des champs : gamme, essence de bois, dimensions, prix à partir de, et une galerie. Le client remplit ça lui-même."),
            (0, "Il saura le faire ?"),
            (1, "Sa fille gère Instagram et elle est à l'aise. Je pense que oui, avec une formation d'une heure."),
            (0, "OK. Prévoyons une heure de formation en visio à la livraison. Priya, tu t'en charges."),
            (1, "Noté pour moi."),
            (0, "Le planning maintenant. Paul, tu estimes combien de jours ?"),
            (2, "Maquettes trois jours, intégration du thème huit jours, formulaire et catalogue trois jours, migration des contenus et recette trois jours. Dix-sept jours au total, disons dix-huit avec la marge."),
            (0, "Dix-huit jours. Et la disponibilité ?"),
            (2, "Je peux démarrer le vingt-deux septembre. En comptant les allers-retours avec le client, une livraison le trente et un octobre est réaliste."),
            (1, "Le client espérait fin octobre pour la saison des cuisines, donc trente et un octobre ça colle."),
            (0, "On acte le trente et un octobre comme date de mise en ligne cible. Budget : dix-huit jours à six cent cinquante euros, ça fait onze mille sept cents euros hors taxes."),
            (1, "Le devis initial parlait de dix mille. Il va tiquer."),
            (0, "On peut découper : dix mille pour le socle, et le catalogue en option à mille sept cents si sa fille le remplit elle-même, sinon on facture la saisie en plus."),
            (1, "Ça me va, je présente comme ça. Je pense qu'il prendra l'option."),
            (0, "Paul, un risque que tu vois ?"),
            (2, "La migration des contenus. Le site actuel a une centaine de pages dont la moitié sont des brouillons ou des doublons. Il faut que quelqu'un décide ce qu'on garde."),
            (0, "Priya, tu peux demander au client un tri avant le vingt-deux ?"),
            (1, "Je lui envoie un export des pages avec une colonne garder ou supprimer. Mais je ne garantis pas qu'il réponde vite."),
            (0, "Si on n'a pas la liste le vingt-deux, on ne migre que les pages qui ont eu du trafic sur les six derniers mois d'après Analytics. Paul, c'est faisable ?"),
            (2, "Oui, j'ai accès à leur Analytics. Je peux sortir la liste en une heure."),
            (0, "Parfait. Autre chose ? Les redirections ?"),
            (2, "Je m'en occupe, on garde les URL quand c'est possible et je fais un plan de redirection pour le reste. Je ne veux pas qu'ils perdent leur référencement local, ils sont premiers sur menuisier Rennes."),
            (1, "Il y a une question que je n'ai pas pu résoudre : le nom de domaine est au nom de l'ancien prestataire. Il faut le récupérer avant la mise en ligne."),
            (0, "Ah, ça c'est bloquant. Tu as le contact de l'ancien prestataire ?"),
            (1, "J'ai un mail, pas de réponse depuis deux semaines. Je vais passer par le client directement, c'est lui le propriétaire légal."),
            (0, "OK, on le garde en question ouverte, à relancer chaque semaine. Bon, je récapitule : thème sur mesure sans slider, formulaire avec Sheet, catalogue en option, mise en ligne le trente et un octobre, budget dix mille plus option mille sept cents. Paul démarre le vingt-deux septembre. Priya voit le client cette semaine."),
            (1, "C'est ça. Je vous envoie le compte rendu ce soir."),
            (2, "Merci à vous deux, bonne journée."),
            (0, "Merci Priya, merci Paul. À jeudi prochain, même heure."),
        ]
    )

    // MARK: - Réunion 2 : point logistique (Moi, Hélène, Marc)

    static let logistics = DemoMeeting(
        title: "Point transfert entrepôt",
        startedAt: date("2026-09-04T14:30:00+02:00"),
        source: "Zoom",
        participants: ["Hélène Roux", "Marc Dubois"],
        turns: [
            (0, "Bonjour Hélène, bonjour Marc. On fait le point sur le transfert de stock vers le nouvel entrepôt."),
            (1, "Bonjour Charles. J'ai le tableau sous les yeux."),
            (2, "Bonjour à tous, Marc à l'appareil. Je suis en voiture, donc si ça coupe je vous rappelle."),
            (0, "Pas de souci. Hélène, on en est où sur les palettes ?"),
            (1, "Sur les cent vingt-huit palettes prévues, quatre-vingt-seize sont parties. Trois camions ont été livrés, le quatrième est parti ce matin."),
            (0, "Donc il reste trente-deux palettes, un camion."),
            (1, "Oui, le cinquième et dernier camion. Il est planifié lundi prochain, le huit septembre."),
            (2, "Je confirme le huit, chargement à huit heures, livraison dans l'après-midi. Le chauffeur est le même que pour le troisième camion, il connaît le quai."),
            (0, "Parfait. Marc, sur les trois camions livrés, il y a eu des casses ?"),
            (2, "Une palette abîmée sur le deuxième camion, du filmage qui a lâché. Le réceptionnaire a noté une réserve sur le bon de livraison, six cartons écrasés."),
            (1, "Je l'ai vue, ce sont des cartons de trolleys cabine bleu grisé. J'ai demandé au nouvel entrepôt de les mettre de côté pour contrôle."),
            (0, "On les compte comment ? Si les produits sont intacts, on les remet en stock."),
            (1, "C'est ce que je leur ai dit. Ils ouvrent les cartons et me disent d'ici jeudi. S'il y a de la casse réelle, on fait une déclaration à l'assurance de Marc."),
            (2, "Pas de problème, on a l'assurance ad valorem sur ce contrat. Envoyez-moi les photos et le bon de livraison signé avec la réserve."),
            (0, "Hélène, tu envoies ça à Marc dès que tu as le retour du contrôle."),
            (1, "Noté."),
            (0, "Deuxième sujet : les écarts de comptage à la réception. Sur le premier camion, on avait un écart de douze pièces."),
            (1, "Je l'ai résolu. Ils comptaient à l'EAN et nous on comptait au SKU, et il y a deux SKU qui partagent le même EAN sur les anciens lots. En réalité il n'y a aucun écart."),
            (0, "Bien vu. Il faut qu'on corrige ça pour de bon, sinon on va avoir le problème à chaque réception."),
            (1, "Je propose de créer un EAN distinct pour l'ancien lot. On le passe dans le logiciel de gestion cette semaine et j'envoie la nouvelle table de correspondance à l'entrepôt."),
            (0, "D'accord, tu t'en charges pour vendredi."),
            (1, "Oui, vendredi au plus tard."),
            (2, "De mon côté je n'ai rien à faire là-dessus ?"),
            (0, "Non Marc, c'est interne. Par contre, sur le dernier camion, il y a une palette de retours SAV, des roues détachées, en vrac dans des bacs. Tu peux prendre du vrac ?"),
            (2, "Si c'est filmé sur palette et que ça ne dépasse pas, oui. Mais des bacs ouverts, non, j'aurai un refus du chauffeur."),
            (1, "Je fais filmer les bacs avec un couvercle. On a du film et des couvercles de bac en stock."),
            (0, "OK. Le sujet des délais maintenant. Le nouvel entrepôt commence à expédier les commandes quand ?"),
            (1, "Ils ont dit qu'ils étaient prêts à expédier dès que le dernier camion est réceptionné et intégré, donc mercredi dix septembre au plus tôt."),
            (0, "Et entre-temps, les commandes clients partent d'où ?"),
            (1, "Toujours de l'ancien entrepôt jusqu'à mardi soir. On a gardé un stock tampon de deux palettes des meilleures ventes exprès pour ça."),
            (0, "Bonne idée. Et ces deux palettes, elles partent comment ?"),
            (2, "Je peux les prendre le mercredi matin avec un petit porteur. C'est un aller simple, je vous fais ça à trois cent vingt euros."),
            (0, "Va pour trois cent vingt. Hélène, tu confirmes à Marc mardi midi le nombre de palettes exact."),
            (1, "Ça marche."),
            (0, "Marc, la facture des cinq camions, tu l'envoies quand ?"),
            (2, "Une facture globale à la livraison du cinquième camion, avec le détail par camion. Je l'envoie le neuf septembre."),
            (0, "Parfait. Et le prix, on est bien sur le devis initial, mille deux cent quatre-vingts euros par camion ?"),
            (2, "Oui, sauf le quatrième qui a attendu deux heures au chargement. Je facture une heure d'attente, soixante euros. Le reste est conforme."),
            (1, "Je confirme l'attente, c'était de notre faute, le chariot était en panne."),
            (0, "OK, pas de discussion, on prend l'heure d'attente. Autre chose ?"),
            (1, "Une question : les documents de transfert pour la comptabilité, on fait un bon de sortie par camion ou un seul global ?"),
            (0, "Je ne sais pas ce que la comptable préfère. Je lui pose la question et je te dis demain."),
            (1, "Merci. Et dernier point, le nouvel entrepôt demande le fichier de stock attendu au format CSV avec les EAN, pas les SKU."),
            (0, "On l'a déjà ce fichier ?"),
            (1, "Presque, il me manque les EAN sur une dizaine de références. Je les récupère auprès du fournisseur."),
            (0, "Bon, je récapitule. Cinquième camion lundi huit, chargement huit heures. Contrôle des six cartons abîmés d'ici jeudi, photos à Marc. Nouvel EAN pour l'ancien lot pour vendredi, Hélène. Deux palettes tampon en petit porteur mercredi, trois cent vingt euros. Facture globale le neuf. Bon de sortie, je reviens vers vous demain."),
            (2, "C'est clair pour moi. Je vous laisse, j'arrive au dépôt."),
            (1, "Merci Marc. Charles, je t'envoie le tableau mis à jour dans l'heure."),
            (0, "Merci Hélène, merci Marc. Bonne journée."),
        ]
    )
}
