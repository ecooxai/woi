// Prints the PipeWire echo-cancel config Woi generates (qa/aec/measure.sh
// runs exactly this config): dart run tool/aec_conf.dart <instance-id>
import 'dart:io';

import 'package:woi/platform/linux/pipewire_aec.dart';

void main(List<String> args) {
  final aec = PipewireEchoCancel(instanceId: args.isEmpty ? 'qa' : args.first);
  stdout.writeln(
    PipewireEchoCancel.config(sourceName: aec.sourceName, captureName: aec.captureName, monitorName: aec.monitorName),
  );
}
