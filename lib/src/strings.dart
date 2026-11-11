/// On-screen texts. Pass your own to [LivenessCheck] to translate or reword.
class LivenessStrings {
  final String front, left, right, up, down;
  final String noFace, oneFaceOnly, uploading, starting, takePhoto, otherWay;

  const LivenessStrings({
    this.front = 'Look straight at the camera',
    this.left = 'Turn your head to your left',
    this.right = 'Turn your head to your right',
    this.up = 'Look up',
    this.down = 'Look down',
    this.noFace = 'Put your face inside the circle',
    this.oneFaceOnly = 'Only one person, please',
    this.uploading = 'Checking…',
    this.starting = 'Starting camera…',
    this.takePhoto = 'Take photo now',
    this.otherWay = 'Turn the other way',
  });

  /// Mongolian. Have a native speaker review the wording before release.
  static const mn = LivenessStrings(
    front: 'Камер руу эгц харна уу',
    left: 'Толгойгоо зүүн тийш эргүүлнэ үү',
    right: 'Толгойгоо баруун тийш эргүүлнэ үү',
    up: 'Дээш харна уу',
    down: 'Доош харна уу',
    noFace: 'Нүүрээ дугуй дотор байрлуулна уу',
    oneFaceOnly: 'Зөвхөн нэг хүн байх ёстой',
    uploading: 'Шалгаж байна…',
    starting: 'Камер нээж байна…',
    takePhoto: 'Одоо зураг авах',
    otherWay: 'Нөгөө тийш эргэнэ үү',
  );

  String forStep(String step) => switch (step) {
        'left' => left,
        'right' => right,
        'up' => up,
        'down' => down,
        _ => front,
      };
}
