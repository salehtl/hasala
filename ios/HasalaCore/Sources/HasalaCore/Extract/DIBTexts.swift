public enum DIBTexts {
  public struct Wording: Sendable, Equatable {
    public let kind: TextDropKind
    public let wording: String
  }

  public static let wholeBody: [Wording] = [
    Wording(
      kind: .oneTimeCode,
      wording: "{n} هو OTP للمشتريات من {any} بمبلغ {amount} {ccy} على بطاقتك {n} لا تشارك مع أي شخص. اتصل على {n}+ في حال لم تقم بالمعاملة ."),
    Wording(
      kind: .oneTimeCode,
      wording:
        "{n} كلمة المرور الخاصة بك لمرة واحدة (OTP) لعملية الشراء عبر الإنترنت في {any} بمبلغ {amount} {ccy} على بطاقة بنك دبي الإسلامي التي تنتهي برقم {n} . إن كلمة المرور هذه صالحة لمدة {n} دقائق فقط. لا تشارك كلمة المرور الخاصة بك لمرة واحدة(OTP) مع أي شخص. اتصل على {n}+ في حال عدم قيامك بهذه العملية."
    ),
    Wording(
      kind: .oneTimeCode,
      wording:
        "Please do not share this OTP with anyone. The One Time Password (OTP) for {any} is {n}, and is valid for the next {n} minutes only."),
    Wording(
      kind: .oneTimeCode,
      wording:
        "Please do not share this OTP with anyone. The One Time Password (OTP) for {any} is {n} and is valid for the next {n} minutes only."),
    Wording(
      kind: .oneTimeCode,
      wording: "Please do not share this OTP with anyone. The OTP for {any} is \"{n}\" This password will be valid for the next {n} minutes only."),
    Wording(
      kind: .oneTimeCode,
      wording: "إن كلمة السر لمرة واحدة الخاص بك هي {n} لتفعيل Apple Pay على بطاقتك من بنك دبي الإسلامي التي تنتهي بالرقم {card}."),
    Wording(kind: .oneTimeCode, wording: "OTP is {n} to {any}. DO NOT SHARE ONE TIME PASSWORD(OTP) WITH ANYONE."),

    Wording(
      kind: .declined,
      wording:
        "تم ادخال رقم سري خاطئ لمعاملتك على بطاقة بنك دبي الإسلامي الخاص بك والمنتهية بالرقم {card}. لديك {n} محاولة قبل إيقاف البطاقة."),
    Wording(
      kind: .declined,
      wording:
        "Your funds transfer request ref# {any} scheduled for {date} could not be processed. Please check your registered email ID for more details"
    ),
    Wording(
      kind: .declined,
      wording:
        "تم إدخال رمز تحقق غير صحيح (مكون من {n} أرقام موجودة على الجهة الخلفية للبطاقة) لمعاملتك على بطاقة دبي الإسلامي الخاصة بك والمنتهية بالرقم. {card} يُرجى إدخال الرمز الصحيح أو التواصل مع {any} على الرقم {n} للمساعدة."
    ),

    Wording(kind: .notice, wording: "تم إيقاف بطاقتك من بنك دبي الإسلامي التي تنتهي بالرقم {card} مؤقتاً على Apple Pay."),
    Wording(kind: .notice, wording: "تم إلغاء تفعيل بطاقتك من بنك دبي الإسلامي التي تنتهي بالرقم {card} بنجاح على Apple Pay."),
    Wording(
      kind: .notice,
      wording:
        "تم تسجيلك الآن لاستخدام Apple pay مع بطاقة بنك دبي الإسلامي التي تنتهي بالرقم {card}. يرجى التواصل مع بنك دبي الإسلامي إذا لم تقم بتقديم هذا الطلب."
    ),
    Wording(kind: .notice, wording: "أنت الآن مسجل لاستخدام تطبيق Apple Pay مع بطاقتك من بنك دبي الإسلامي التي تنتهي بالرقم {card}"),
    Wording(kind: .notice, wording: "تم إيقاف بطاقة بنك دبي الإسلامي الخاصة بك والمنتهية بالرقم {card}. يرجى الاتصال على {n} للمساعدة"),
    Wording(
      kind: .notice,
      wording:
        "تم إيقاف بطاقة بنك دبي الإسلامي الخاص بك والمنتهية بالرقم {card} بسبب تجاوز عدد المحاولات المسموح بها لإدخال الرقم السري الصحيح. للمساعدة{any} يرجى الاتصال على {n}"
    ),
    Wording(kind: .notice, wording: "عميلنا العزيز,لقد تم تنفيذ طلب الإيقاف المؤقت للبطاقة المنتهية برقم{card} حسب طلبك"),
    Wording(kind: .notice, wording: "تم الغاء الإيقاف المؤقت على بطاقة بنك دبي الإسلامي الخاصة بك والمنتهية بالرقم {card}. يمكنك استخدام البطاقة."),
    Wording(kind: .notice, wording: "عميلنا العزيز,لقد تم إعادة تفعيل البطاقة المنتهية برقم {card} حسب طلبك"),
    Wording(
      kind: .notice,
      wording:
        "تهانينا على بطاقتك الجديدة من بنك دبي الإسلامي والمنتهية بالرقم {card}. يرجى إنشاء رقم التعريف الشخصي للبطاقة قبل استخدامها، من خلال ماكينات الصراف الآلي التابعة لبنك دبي الإسلامي/ تطبيق الهاتف/ {n}"
    ),
    Wording(
      kind: .notice,
      wording:
        "تهانينا! لقد نجحت في إنشاء رقم التعريف الشخصي لبطاقة بنك دبي الإسلامي الخاصة بك والتي تنتهي بالرقم{card} عبرالتطبيق . استمتع باستخدام بطاقتك الجديدة من بنك دبي الإسلامي."
    ),
    Wording(
      kind: .notice,
      wording:
        "رقم تذكرة الخدمة الخاص بك في بنك دبي الإسلامي هو {n} نخدم حالياً رقم {n}، وستتم خدمتك قريباً. حمّل تطبيق بنك دبي الإسلامي لأكثر من {n} خدمة مصرفية في متناول يديك . www.dib.ae/app"
    ),
    Wording(kind: .notice, wording: "عزيزي متعامل بنك دبي الإسلامي، رقمكم هو {n}.نخدم حالياً رقم{n}،سيتم خدمتكم قريباً"),
    Wording(kind: .notice, wording: "{any} Request# {n} is raised at {any}"),
    Wording(kind: .notice, wording: "{any} Request# {n} has been raised at {any}. You will hear from us Soon."),
    Wording(kind: .notice, wording: "Dear {any} we have received your {any} Request# {n},DIB team is working on it and will contact you shortly. {any}"),
    Wording(kind: .notice, wording: "Dear {any} Request# {n}, special retention offer for {any}"),
    Wording(kind: .notice, wording: "Hello {any}! Your card cancellation request #{n} {any}"),
    Wording(kind: .notice, wording: "Hello {any}! Your card cancellation request # {n} {any}"),
    Wording(kind: .notice, wording: "Dear Customer, your transaction/s dispute request Ref No {n} has been resolved with the following comments {any}"),
    Wording(
      kind: .notice,
      wording:
        "عزيزي المتعامل، بعض المعاملات التي تمت على بطاقتك للخصم من بنك دبي الإسلامي في الفترة ما بين {any} لم يتم خصمها في نفس التاريخ. سيتم الآن خصم هذه المعاملات من حسابك {any}"
    ),

    Wording(
      kind: .promotion,
      wording:
        "عزيزي {any}, اضغط الرابط الآن '{any}' للحصول على التمويل الشخصى الموافق عليه مسبقاً من بنك دبي الإسلامي. تطبق الشروط والأحكام."),
    Wording(
      kind: .promotion,
      wording:
        "احصل على بطاقتك الائتمانية من بنك دبي الإسلامي. لا يتطلب أي أوراق أو وقت انتظار! اضغط هنا '{any}' للحصول عليه الآن! تطبق الشروط والأحكام."
    ),
    Wording(
      kind: .promotion,
      wording: "لقد تمت الموافقة مسبقًا على التمويل الشخصي من بنك دبي الإسلامي! اضغط هنا '{any}' للتقديم الآن! تطبق الشروط والأحكام."),
    Wording(
      kind: .promotion,
      wording:
        "{n} step away to get your DIB Credit Card. Just upload your documents and accept the T&Cs to get your Card. Click {any} NOW!"),
  ]
}
