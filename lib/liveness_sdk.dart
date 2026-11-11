/// Head-turn liveness capture.
///
/// Your backend creates a session on the liveness server and passes
/// `sessionId`, `sessionToken` and `turns` to the app. Show [LivenessCheck];
/// when it reports [LivenessStatus.completed], your backend reads the verdict
/// from the server. The app never sees the verdict.
library;

export 'src/liveness_check.dart';
export 'src/strings.dart';
