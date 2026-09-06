import Foundation

/// Prompts de l'assistant, en français. Fonctions pures : elles rendent (system, user) et rien d'autre.
/// Chaque prompt système contient une phrase repère (`Marker`) qui permet à `MockLLM.demo()` de le reconnaître.
public enum Prompts {

    public typealias Pair = (system: String, user: String)

    /// Phrases repères, une par prompt, présentes mot pour mot dans le prompt système correspondant.
    public enum Marker {
        public static let identifySpeakers = "Tu identifies les personnes qui parlent"
        public static let summarize = "Tu rédiges le compte rendu d'une réunion"
        public static let catchUp = "L'utilisateur s'est absenté quelques minutes"
        public static let ask = "Tu réponds aux questions de l'utilisateur sur ses réunions"
        public static let suggestTitle = "Propose un titre pour cette réunion"
    }

    /// Règles de forme communes à toutes les sorties.
    public static let formRules = """
    Règles de forme : français correct avec les accents ; jamais de tiret cadratin (utilise une virgule, \
    deux points ou un tiret simple) ; aucun emoji ; pas de formule d'introduction ni de conclusion.
    """

    /// Sections attendues dans un résumé, dans l'ordre.
    public static let summarySections = ["## En bref", "## Décisions", "## Par thème", "## Prochaines étapes", "## Questions ouvertes"]

    // MARK: - Nommage des locuteurs

    /// `transcript` : lignes `[mm:ss] Étiquette : texte` où les étiquettes sont « Moi », « Locuteur 2 »…
    /// `participants` : invités du calendrier ; `dictionary` : termes du dictionnaire personnel (noms propres).
    public static func identifySpeakers(transcript: String, participants: [String], dictionary: [String],
                                        userName: String) -> Pair {
        let system = """
        \(Marker.identifySpeakers) dans la transcription d'une réunion en français. \
        Les tours de parole sont étiquetés « Moi » (l'utilisateur, qui s'appelle \(userName)) et « Locuteur 2 », \
        « Locuteur 3 »... pour les autres personnes. Ta tâche : pour chaque étiquette « Locuteur N », \
        donner le nom de la personne quand la transcription permet de le savoir.

        Un nom n'est acceptable que s'il est prononcé ou déductible sans ambiguïté :
        - la personne se présente elle-même (« moi c'est Paul », « ici Priya », « Marc à l'appareil ») ;
        - quelqu'un s'adresse à elle juste avant ou juste après qu'elle parle (« merci Priya », « Paul, tu en penses quoi ? » \
        suivi de sa réponse) ;
        - un seul invité du calendrier reste sans étiquette et un seul locuteur reste sans nom.
        Sinon, name vaut null. N'invente jamais un nom. Ne renomme jamais « Moi ». \
        Attention aux pièges : un prénom cité en parlant d'une personne absente n'est pas un locuteur ; \
        « merci Paul » désigne quelqu'un d'autre que celui qui le dit.

        Les invités du calendrier et le dictionnaire personnel sont des indices, pas des preuves : ils servent à \
        orthographier correctement un prénom entendu (nom complet si l'invité correspond), ou à attribuer le dernier invité restant.

        Réponds uniquement avec un objet JSON de la forme :
        {"speakers":[{"label":"Locuteur 2","name":"Priya Sharma","confidence":0.9,"evidence":"[03:12] Moi : merci Priya"}]}
        - confidence entre 0 et 1 : 0.9 ou plus si le nom est prononcé explicitement pour cette personne ; \
        0.7 à 0.85 si déduit par élimination avec les invités ; moins de 0.5 pour une simple hypothèse.
        - evidence : la ligne de la transcription qui justifie le nom, copiée telle quelle.
        - Un locuteur dont le nom est inconnu : "name": null, "confidence": 0, "evidence": "".
        - Tous les locuteurs « Locuteur N » présents dans la transcription doivent figurer dans la liste.
        \(formRules)
        """
        let guests = participants.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let terms = dictionary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let user = """
        Utilisateur (étiquette « Moi ») : \(userName)
        Invités du calendrier : \(guests.isEmpty ? "aucun" : guests.joined(separator: ", "))
        Dictionnaire personnel : \(terms.isEmpty ? "vide" : terms.joined(separator: ", "))

        Transcription :
        \(transcript)
        """
        return (system, user)
    }

    // MARK: - Résumé

    public static func summarize(transcript: String, title: String, date: Date) -> Pair {
        let system = """
        \(Marker.summarize) à partir de sa transcription horodatée, en français. \
        « Moi » désigne l'utilisateur pour qui tu écris : parle de lui à la deuxième personne (« tu valides le budget », \
        « toi : envoyer le devis »), jamais « Moi valide ». Désigne les autres par leur nom quand il est connu, \
        sinon par leur étiquette (« Locuteur 2 »).

        Sortie : du markdown avec EXACTEMENT ces cinq sections, dans cet ordre, avec ces titres à l'identique, \
        rien avant la première ni après la dernière :

        ## En bref
        Trois lignes au maximum : de quoi il s'agissait, où on en est. Si la transcription contient une marque \
        de passage omis, signale-le ici en une phrase.

        ## Décisions
        Une puce par décision réellement prise, pas les pistes seulement évoquées. Si aucune : une seule puce « aucune ».

        ## Par thème
        Un sous-titre `###` par thème abordé, dans l'ordre de la réunion (3 à 7 thèmes). Sous chaque thème, \
        des puces courtes ; précise qui a dit quoi quand c'est utile (« Paul mesure... », « Priya s'inquiète de... »).

        ## Prochaines étapes
        Une puce par action, au format « qui : quoi, quand ». Si l'échéance n'est pas dite, écris « échéance non précisée ». \
        Si aucune : « aucune ».

        ## Questions ouvertes
        Une puce par point resté sans réponse ou bloquant. Si aucune : « aucune ».

        Règles de fond : uniquement ce qui est dans la transcription, jamais d'invention ni d'interprétation \
        au-delà de ce qui est dit ; garde les chiffres, dates, montants et noms exacts ; les nombres en toutes lettres \
        de la transcription s'écrivent en chiffres ; reprends les échéances telles qu'elles sont dites (« à la livraison », \
        « cette semaine ») sans les convertir en date ; attribue chaque action à la personne qui l'a prise en charge.
        \(formRules)
        """
        let user = """
        Réunion : « \(title) », le \(frenchDate(date))

        Transcription :
        \(transcript)
        """
        return (system, user)
    }

    // MARK: - Qu'est-ce que j'ai raté ?

    public static func catchUp(recentTranscript: String) -> Pair {
        let system = """
        \(Marker.catchUp) d'une réunion en cours. À partir des dernières minutes de transcription, \
        dis-lui ce qu'il a raté : les faits, décisions et demandes de l'extrait, sans commentaire. \
        « Moi » désigne l'utilisateur lui-même ; si des tours de « Moi » figurent dans l'extrait, résume-les aussi \
        (il n'a pas tout suivi), à la deuxième personne (« tu as acté... »).
        Sortie : trois puces au maximum, 60 mots au total au maximum, en français, factuel, uniquement ce qui est \
        dans l'extrait, en commençant directement par la première puce. Réponds « - Rien de notable. » seulement si \
        l'extrait est vide ou ne contient que des salutations.
        \(formRules)
        """
        let user = """
        Dernières minutes de la réunion :
        \(recentTranscript.isEmpty ? "(vide)" : recentTranscript)
        """
        return (system, user)
    }

    // MARK: - Ask anything

    /// `contextBlocks` : un bloc par réunion, en-tête `[Réunion « titre » du JJ/MM/AAAA] (meeting_id: ...)`
    /// puis une ligne `[mm:ss] Nom : texte` par tour de parole. Voir `Assistant.contextHeader`.
    public static func ask(question: String, contextBlocks: [String]) -> Pair {
        let system = """
        \(Marker.ask), uniquement à partir des extraits de transcription fournis. \
        Les extraits sont groupés par réunion : chaque groupe commence par une ligne \
        [Réunion « titre » du JJ/MM/AAAA] (meeting_id: identifiant) et chaque tour de parole par son horodatage [mm:ss] \
        ou [h:mm:ss]. « Moi » désigne l'utilisateur qui pose la question.

        Format de la réponse, dans cet ordre :
        1. Une réponse courte en markdown (quelques phrases ou quelques puces), en français, qui donne les faits utiles \
        en précisant qui l'a dit et dans quelle réunion quand il y en a plusieurs.
        2. Puis, en toute fin, un bloc de code json (ouvert par ```json et fermé par ```) :
        {"citations":[{"meeting_id":"identifiant copié depuis l'en-tête","start_seconds":727,"quote":"passage exact"}]}
        Une citation par fait avancé : meeting_id copié tel quel depuis l'en-tête du groupe ; start_seconds = horodatage \
        du tour de parole converti en secondes ([12:07] donne 727) ; quote = une phrase du tour de parole, copiée à l'identique.

        Si les extraits ne permettent pas de répondre, réponds exactement « Je ne trouve pas ça dans tes réunions. » \
        suivi du bloc json avec une liste de citations vide. Ne complète jamais avec des connaissances extérieures \
        et ne déduis pas ce qui n'est pas dit.
        \(formRules)
        """
        let context = contextBlocks.isEmpty ? "(aucun extrait ne correspond à la question)" : contextBlocks.joined(separator: "\n\n")
        let user = """
        Question : \(question)

        Extraits :

        \(context)
        """
        return (system, user)
    }

    // MARK: - Titre

    public static func suggestTitle(transcript: String) -> Pair {
        let system = """
        \(Marker.suggestTitle) à partir de sa transcription : 3 à 6 mots, en français, concret \
        (le sujet réel de la réunion, pas les mots « réunion », « point » ou « échange »), sans guillemets, sans ponctuation finale, \
        sans emoji ni tiret cadratin. Réponds avec le titre seul, sur une seule ligne, sans explication.
        """
        let user = """
        Transcription :
        \(transcript)
        """
        return (system, user)
    }

    // MARK: - Utilitaires

    /// « vendredi 5 septembre 2026 à 10:00 ».
    public static func frenchDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateStyle = .full
        df.timeStyle = .short
        return df.string(from: date)
    }

    /// « 05/09/2026 ».
    public static func shortDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "dd/MM/yyyy"
        return df.string(from: date)
    }
}
