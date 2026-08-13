import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'direct_link.dart';
import 'layout.dart';
import 'pairing_dialogs.dart';
import 'qr_pairing.dart';
import 'storage.dart';
import 'sync_page.dart';

/// The direct tab: its own place in the app, because a way of reaching a device
/// is not a mode of the device list, and a switch inside that list hid it from
/// anyone who had not gone looking.
class DirectConnectPage extends StatelessWidget {
  const DirectConnectPage({
    super.key,
    required this.self,
    required this.trust,
    this.folders,
    this.links,
    this.scanner,
    this.server,
    this.autoLoad = true,
  });

  final DeviceInfo self;
  final TrustStore trust;

  /// What this device shares, handed on to the sync screen so a folder already
  /// chosen here is not asked for again.
  final SharedFolders? folders;
  final DirectLinkControls? links;
  final QrScanner? scanner;
  final PeerServer? server;
  final bool autoLoad;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).directConnect)),
      body: DirectConnectPanel(
        self: self,
        trust: trust,
        folders: folders,
        links: links,
        scanner: scanner,
        server: server,
        autoLoad: autoLoad,
      ),
    );
  }
}

/// Which end of a direct connection this device is.
enum DirectRole {
  /// Wait to be dialled: show this device's addresses and stay put.
  receive,

  /// Dial the other device, at an address read off its screen or found on the
  /// link.
  send,
}

/// Connecting two devices with no network between them.
///
/// Discovery needs a network that carries multicast or broadcast between the
/// two devices, and there are ordinary situations with no such network: a phone
/// on mobile data, a guest Wi-Fi that isolates its clients, a laptop with no
/// Wi-Fi at all. This panel is for those, and it has two jobs.
///
/// The first is making a link where there is none. There are exactly two ways
/// two devices can be wired together without help: one hosts a hotspot the
/// other joins, or a USB cable between them is turned into a network. Both are
/// the system's to switch on, not the app's, so what this offers is a hotspot
/// where the platform allows an app to raise one, and the right settings screen
/// where it does not.
///
/// The second is finding the other device on that link once it exists. A cable
/// or a hotspot is a network of two, so if the announcements do not come
/// through - which is exactly where they are least reliable - knocking on every
/// address on it is quick and finds the one other machine there. Failing all of
/// that, an address typed by hand always works.
///
/// Bluetooth was the obvious alternative and is the wrong tool: it needs native
/// code on both platforms (a plugin on Android, BlueZ over D-Bus on Linux),
/// which this project deliberately does not have, and even at its best it moves
/// a folder of notes an order of magnitude slower than a cable or a hotspot.
class DirectConnectPanel extends StatefulWidget {
  const DirectConnectPanel({
    super.key,
    required this.self,
    required this.trust,
    this.folders,
    this.links,
    this.scanner,
    this.server,
    this.initialRole = DirectRole.receive,
    this.autoLoad = true,
  });

  final DeviceInfo self;
  final TrustStore trust;

  /// What this device shares, so the sync screen this panel opens knows where a
  /// folder lands here without asking a question already answered.
  final SharedFolders? folders;

  /// Reads QR codes with the camera. Null where there is none.
  final QrScanner? scanner;

  /// The listening server, so a code shown here can carry a token it will
  /// accept. Without one this device can be dialled but cannot show a code.
  final PeerServer? server;

  /// What this platform can do about making a link. Null where it can do
  /// nothing - the desktop - in which case the panel explains instead of
  /// offering.
  final DirectLinkControls? links;

  final DirectRole initialRole;

  /// Whether to read this device's addresses on open. Off in widget tests,
  /// where enumerating real interfaces is neither wanted nor stable.
  final bool autoLoad;

  @override
  State<DirectConnectPanel> createState() => _DirectConnectPanelState();
}

class _DirectConnectPanelState extends State<DirectConnectPanel> {
  late DirectRole _role = widget.initialRole;
  final _address = TextEditingController();

  List<LocalAddress> _addresses = const [];
  bool _loadingAddresses = false;

  bool _canHostHotspot = false;
  bool _startingHotspot = false;
  HotspotCredentials? _hotspot;
  bool _hotspotFailed = false;

  bool _probing = false;
  List<String>? _foundOnLink;

  bool _connecting = false;
  String? _failure;

  /// The code currently on screen, and the token it carries. Both die together:
  /// a token outliving its code is a pairing nobody is watching for.
  QrPayload? _shown;
  QrPairingToken? _shownToken;
  bool _preparingQr = false;
  String? _pairedWith;
  StreamSubscription<IncomingPairing>? _pairings;

  /// The links that are two devices and nothing else: a cable, or a hotspot.
  List<LocalAddress> get _directLinks =>
      [for (final a in _addresses) if (a.kind.isDirect) a];

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      _loadAddresses();
      _askWhatIsPossible();
    }
    // The other device pairing off this screen's code is news worth showing
    // here, where the code is: it is the end of what this screen was for.
    _pairings = widget.server?.pairingRequests.listen((request) {
      if (!mounted || !request.settled) return;
      setState(() {
        _pairedWith = request.peer.name;
        _shown = null;
        _shownToken = null;
      });
    });
  }

  @override
  void dispose() {
    _pairings?.cancel();
    // The code is off screen the moment this is: nothing may pair on a token
    // nobody is looking at.
    if (widget.server?.qrToken == _shownToken) widget.server?.qrToken = null;
    _address.dispose();
    super.dispose();
  }

  Future<void> _askWhatIsPossible() async {
    final can = await widget.links?.canHostHotspot() ?? false;
    if (mounted) setState(() => _canHostHotspot = can);
  }

  Future<void> _loadAddresses() async {
    setState(() => _loadingAddresses = true);
    final found = await localAddresses();
    if (!mounted) return;
    setState(() {
      _addresses = found;
      _loadingAddresses = false;
    });
  }

  // ------------------------------------------------------------------- link

  Future<void> _startHotspot() async {
    setState(() {
      _startingHotspot = true;
      _hotspotFailed = false;
    });
    final credentials = await widget.links?.startHotspot();
    if (!mounted) return;
    setState(() {
      _startingHotspot = false;
      _hotspot = credentials;
      _hotspotFailed = credentials == null;
    });
    // The hotspot brings up an interface of its own, and its address is what
    // the other device will be told to dial.
    if (credentials != null) await _loadAddresses();
  }

  Future<void> _stopHotspot() async {
    await widget.links?.stopHotspot();
    if (!mounted) return;
    setState(() => _hotspot = null);
    await _loadAddresses();
  }

  // --------------------------------------------------------------------- qr

  /// Puts a code on screen with everything the other device needs: the network
  /// to join, where to dial, and a one-time token that lets it pair without
  /// anybody comparing digits.
  ///
  /// The hotspot comes up as part of showing the code, because a code carrying
  /// an address on a network the other device cannot reach would be a code that
  /// scans and then fails.
  Future<void> _showQr() async {
    final server = widget.server;
    if (server == null) return;

    setState(() {
      _preparingQr = true;
      _pairedWith = null;
      _hotspotFailed = false;
    });

    if (_directLinks.isEmpty && _canHostHotspot) await _startHotspot();
    await _loadAddresses();
    if (!mounted) return;

    // Direct links first: an address on the hotspot just raised is the one the
    // scanner will be able to reach, whatever else this device is attached to.
    final ordered = [
      for (final address in _addresses)
        if (address.kind.isDirect) address.address,
      for (final address in _addresses)
        if (!address.kind.isDirect && address.kind != LinkKind.mobile)
          address.address,
    ];

    final token = QrPairingToken.generate();
    server.qrToken = token;

    setState(() {
      _preparingQr = false;
      _shownToken = token;
      _shown = QrPayload(
        name: widget.self.name,
        platform: widget.self.platform,
        addresses: ordered,
        port: widget.self.port,
        token: token.value,
        wifiSsid: _hotspot?.ssid,
        wifiPassphrase: _hotspot?.passphrase,
      );
    });
  }

  void _hideQr() {
    if (widget.server?.qrToken == _shownToken) widget.server?.qrToken = null;
    setState(() {
      _shown = null;
      _shownToken = null;
    });
  }

  /// Reads the other device's code and does everything it says: joins the
  /// network it names, finds which of its addresses answers, and pairs with the
  /// token it carries - no digits to compare, because scanning the code is the
  /// stronger version of that check.
  Future<void> _scanQr() async {
    final scanner = widget.scanner;
    if (scanner == null) return;
    final l10n = AppLocalizations.of(context);

    final scanned = await scanner.scan(context);
    if (scanned == null || !mounted) return;

    final payload = QrPayload.decode(scanned);
    if (payload == null) {
      setState(() => _failure = l10n.qrNotOurs);
      return;
    }

    final cancel = Completer<void>();
    _cancelDial = cancel;
    setState(() {
      _connecting = true;
      _failure = null;
    });

    if (payload.hasWifi && widget.links != null) {
      final joined = await widget.links!
          .joinWifi(payload.wifiSsid!, payload.wifiPassphrase ?? '');
      if (!mounted) return;
      if (!joined) {
        setState(() {
          _connecting = false;
          _failure = l10n.qrJoinFailed(payload.wifiSsid!);
        });
        return;
      }
      // The network has just come up; the far end needs a moment to be
      // listening on it.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
    }

    for (final address in payload.addresses) {
      if (cancel.isCompleted) break;
      if (!await _reachable(address, payload.port, cancel.future)) continue;
      if (!mounted) return;

      final result = await PairingClient(widget.self, widget.trust).pair(
        address,
        payload.port,
        token: payload.token,
        cancel: cancel.future,
      );
      if (!mounted) return;

      if (result.isPaired && result.peer != null) {
        final trusted = await widget.trust.get(result.peer!.id);
        if (trusted == null || !mounted) return;
        setState(() => _connecting = false);
        await _openSync(
          trusted,
          DeviceInfo(
            id: trusted.id,
            name: trusted.name,
            platform: trusted.platform,
            port: payload.port,
            address: address,
          ),
        );
        return;
      }

      setState(() {
        _connecting = false;
        _failure = l10n.directFailed(
            '$address:${payload.port}', result.error ?? l10n.noResult);
      });
      return;
    }

    setState(() {
      _connecting = false;
      // Giving up is not a failure to report back.
      _failure = cancel.isCompleted ? null : l10n.qrUnreachable(payload.name);
    });
  }

  // ------------------------------------------------------------------ probe

  /// Knocks on every address of every direct link, and offers what answers.
  Future<void> _findOnLink() async {
    setState(() {
      _probing = true;
      _foundOnLink = null;
      _failure = null;
    });

    final probe = LinkProbe(port: widget.self.port);
    final found = <String>[];
    for (final link in _directLinks) {
      found.addAll(await probe.sweep(link));
    }
    if (!mounted) return;

    setState(() {
      _probing = false;
      _foundOnLink = found;
      // One answer is the answer: a link of two devices has one other device.
      if (found.length == 1) {
        _address.text = '${found.single}:${widget.self.port}';
      }
    });
  }

  // ---------------------------------------------------------------- dialling

  /// Splits what the user typed into a host and a port, accepting both
  /// `192.168.43.1` and the `192.168.43.1:47800` that the other device shows.
  (String, int)? _parseTarget(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;

    final colon = text.lastIndexOf(':');
    if (colon == -1) return (text, widget.self.port);

    final port = int.tryParse(text.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return null;
    final host = text.substring(0, colon).trim();
    return host.isEmpty ? null : (host, port);
  }

  /// Fires when the user gives up while a connection is still being made.
  Completer<void>? _cancelDial;

  void _cancelConnecting() {
    if (_cancelDial?.isCompleted == false) _cancelDial!.complete();
  }

  Future<void> _connect() async {
    final l10n = AppLocalizations.of(context);
    final target = _parseTarget(_address.text);
    if (target == null) {
      setState(() => _failure = l10n.directBadAddress);
      return;
    }
    final (host, port) = target;

    final cancel = Completer<void>();
    _cancelDial = cancel;
    setState(() {
      _connecting = true;
      _failure = null;
    });

    // One quick knock before anything else. Without it a typo costs a ten
    // second connect timeout for every pairing this device holds and another
    // for the pairing attempt, all to arrive at the same answer.
    final reachable = await _reachable(host, port, cancel.future);
    if (!mounted) return;
    if (cancel.isCompleted) {
      setState(() => _connecting = false);
      return;
    }
    if (!reachable) {
      setState(() {
        _connecting = false;
        _failure = l10n.directFailed('$host:$port', l10n.directNoAnswer);
      });
      return;
    }

    // A device dialled before is a device already paired, and asking the user
    // to confirm a code every time they reconnect over a cable would be a
    // nuisance with nothing to show for it. So try the pairings we hold first;
    // the one that authenticates is who is on the other end.
    final known = await _openKnown(host, port);
    if (known != null) {
      if (mounted) setState(() => _connecting = false);
      await _openSync(known.$1, known.$2);
      return;
    }
    if (!mounted) return;

    final result = await _pair(host, port);
    if (!mounted) return;
    setState(() => _connecting = false);

    if (result == null || !result.isPaired) {
      if (result != null && result.status == PairingStatus.failed) {
        setState(() =>
            _failure = l10n.directFailed('$host:$port', '${result.error}'));
      }
      return;
    }

    final peer = result.peer;
    if (peer == null) return;
    final trusted = await widget.trust.get(peer.id);
    if (trusted == null || !mounted) return;
    await _openSync(
      trusted,
      DeviceInfo(
        id: trusted.id,
        name: trusted.name,
        platform: trusted.platform,
        port: port,
        address: host,
      ),
    );
  }

  /// Whether anything at all is listening there, answered in a few seconds
  /// rather than the transport's patient ten - or the moment the user gives up.
  Future<bool> _reachable(String host, int port, Future<void> cancel) async {
    try {
      final conn = await PeerConnection.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
        cancel: cancel,
      );
      await conn.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tries each device already paired with, against this address. Returns the
  /// one that answers, or null if nothing there knows us.
  Future<(TrustedPeer, DeviceInfo)?> _openKnown(String host, int port) async {
    for (final trusted in await widget.trust.all()) {
      try {
        final client = await SyncClient.connect(
          host,
          port,
          self: widget.self,
          trusted: trusted,
        );
        // Only a probe: the sync screen opens its own session, and holding two
        // would leave one of them dangling on the far side.
        await client.close();
        return (
          trusted,
          DeviceInfo(
            id: trusted.id,
            name: trusted.name,
            platform: trusted.platform,
            port: port,
            address: host,
          ),
        );
      } catch (_) {
        // Not this one: either nothing is listening, or the device there does
        // not know this pairing. Pairing afresh is the answer to both.
      }
    }
    return null;
  }

  Future<PairingResult?> _pair(String host, int port) async {
    final code = ValueNotifier<String?>(null);
    final cancel = Completer<void>();
    final future = PairingClient(widget.self, widget.trust).pair(
      host,
      port,
      onCode: (_, value) => code.value = value,
      cancel: cancel.future,
    );

    if (mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => OutgoingPairingDialog(
          name: '$host:$port',
          code: code,
          result: future,
          onCancel: () {
            if (!cancel.isCompleted) cancel.complete();
          },
        ),
      );
    }
    code.dispose();
    return future;
  }

  Future<void> _openSync(TrustedPeer trusted, DeviceInfo device) async {
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncPage(
        self: widget.self,
        trusted: trusted,
        device: device,
        folders: widget.folders,
        // Dialling a device by hand or off a code is asking for the sync too:
        // the address was typed for a reason.
        autoSync: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return ContentPane(
      child: ListView(
      padding: const EdgeInsets.fromLTRB(Layout.gutter, Layout.gutter,
          Layout.gutter, Layout.section + Layout.snug),
      children: [
        // The way this is meant to go: one device shows a code, the other
        // reads it, and nothing is typed or compared by anybody.
        _QrActions(
          canShow: widget.server != null,
          canScan: widget.scanner != null,
          preparing: _preparingQr,
          busy: _connecting,
          showing: _shown != null,
          onShow: _showQr,
          onHide: _hideQr,
          onScan: _scanQr,
        ),
        if (_pairedWith != null) ...[
          const SizedBox(height: Layout.gap),
          _PairedNotice(name: _pairedWith!),
        ],
        if (_shown != null) ...[
          const SizedBox(height: Layout.gutter),
          Center(child: PairingQrCode(data: _shown!.encode())),
          const SizedBox(height: Layout.gutter),
          QrDetails(payload: _shown!),
        ],
        if (_failure != null) ...[
          const SizedBox(height: Layout.gap),
          Text(
            _failure!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],

        const SizedBox(height: Layout.section),
        // Under the codes, because it is what to do when they cannot be used:
        // no camera, or no network for the address in the code to be on.
        _LinkSection(
          links: widget.links,
          canHostHotspot: _canHostHotspot,
          starting: _startingHotspot,
          hotspot: _hotspot,
          failed: _hotspotFailed,
          directLinks: _directLinks,
          onStartHotspot: _startHotspot,
          onStopHotspot: _stopHotspot,
        ),
        const SizedBox(height: Layout.section),

        // Everything below is the fallback for when a camera is not an option:
        // read an address off one screen, type it on the other.
        ExpansionTile(
          title: Text(l10n.directByHand,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: Layout.gap),
          shape: const Border(),
          collapsedShape: const Border(),
          children: [
            SegmentedButton<DirectRole>(
              segments: [
                ButtonSegment(
                  value: DirectRole.receive,
                  icon: const Icon(Icons.download),
                  label: Text(l10n.directReceive),
                ),
                ButtonSegment(
                  value: DirectRole.send,
                  icon: const Icon(Icons.upload),
                  label: Text(l10n.directSend),
                ),
              ],
              selected: {_role},
              onSelectionChanged: (selection) =>
                  setState(() => _role = selection.first),
            ),
            const SizedBox(height: Layout.gutter),
            if (_role == DirectRole.receive)
              _ReceivePanel(
                port: widget.self.port,
                addresses: _addresses,
                loading: _loadingAddresses,
                onReload: _loadAddresses,
              )
            else
              _SendPanel(
                controller: _address,
                connecting: _connecting,
                failure: null,
                probing: _probing,
                canProbe: _directLinks.isNotEmpty,
                found: _foundOnLink,
                onProbe: _findOnLink,
                onPick: (address) {
                  _address.text = '$address:${widget.self.port}';
                  _connect();
                },
                onConnect: _connect,
                onCancel: _cancelConnecting,
              ),
          ],
        ),
        const SizedBox(height: Layout.section),
        _NoNetworkNote(),
      ],
      ),
    );
  }
}

/// The one thing no button on this screen can fix, said once at the bottom:
/// mobile data alone cannot carry a direct connection, however many bars it
/// shows. Worth stating, because it is the assumption people arrive with.
class _NoNetworkNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.tips_and_updates_outlined,
              size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppLocalizations.of(context).directHowTo,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pair of buttons this screen is really about.
class _QrActions extends StatelessWidget {
  const _QrActions({
    required this.canShow,
    required this.canScan,
    required this.preparing,
    required this.busy,
    required this.showing,
    required this.onShow,
    required this.onHide,
    required this.onScan,
  });

  final bool canShow;
  final bool canScan;
  final bool preparing;
  final bool busy;
  final bool showing;
  final Future<void> Function() onShow;
  final VoidCallback onHide;
  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (canScan)
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || preparing ? null : onScan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(l10n.qrScan),
                ),
              ),
            if (canScan && canShow) const SizedBox(width: Layout.gap),
            if (canShow)
              Expanded(
                child: showing
                    ? OutlinedButton.icon(
                        onPressed: onHide,
                        icon: const Icon(Icons.visibility_off),
                        label: Text(l10n.qrHide),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: busy || preparing ? null : onShow,
                        icon: preparing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.qr_code_2),
                        label: Text(
                            preparing ? l10n.hotspotStarting : l10n.qrShow),
                      ),
              ),
          ],
        ),
        const SizedBox(height: Layout.snug),
        Text(
          canScan ? l10n.qrExplain : l10n.qrExplainNoCamera,
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, height: 1.45),
        ),
      ],
    );
  }
}

/// The other device took the code and paired. Said here because this is the
/// screen that was waiting for it.
class _PairedNotice extends StatelessWidget {
  const _PairedNotice({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(Layout.gap),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: Layout.cardCorners,
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: colors.onPrimaryContainer, size: 20),
          const SizedBox(width: Layout.gap),
          Expanded(
            child: Text(
              AppLocalizations.of(context).pairedWith(name),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: colors.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Making a link where there is none, and saying whether there is one.
class _LinkSection extends StatelessWidget {
  const _LinkSection({
    required this.links,
    required this.canHostHotspot,
    required this.starting,
    required this.hotspot,
    required this.failed,
    required this.directLinks,
    required this.onStartHotspot,
    required this.onStopHotspot,
  });

  final DirectLinkControls? links;
  final bool canHostHotspot;
  final bool starting;
  final HotspotCredentials? hotspot;
  final bool failed;
  final List<LocalAddress> directLinks;
  final Future<void> Function() onStartHotspot;
  final Future<void> Function() onStopHotspot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return AppCard(
      padding: const EdgeInsets.all(Layout.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.directHowToConnect,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),

          // What is already up, which is the thing worth knowing first: with a
          // direct link in place the rest of this section is not needed.
          if (directLinks.isEmpty)
            Text(l10n.directNoLink,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant))
          else
            for (final link in directLinks)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                      link.kind == LinkKind.usb
                          ? Icons.usb
                          : Icons.wifi_tethering,
                      size: 18,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${linkLabel(l10n, link.kind)} · ${link.address}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),

          if (hotspot != null) ...[
            const SizedBox(height: 12),
            _HotspotCard(hotspot: hotspot!),
          ],
          if (failed) ...[
            const SizedBox(height: 12),
            Text(l10n.hotspotFailed,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.error)),
          ],

          const SizedBox(height: 16),
          if (links == null)
            // A desktop cannot raise a hotspot or open a phone's settings, so
            // the only useful thing here is what the user has to do themselves.
            Text(l10n.desktopLinkHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.45))
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canHostHotspot)
                  if (hotspot == null)
                    FilledButton.tonalIcon(
                      onPressed: starting ? null : onStartHotspot,
                      icon: starting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering),
                      label: Text(starting
                          ? l10n.hotspotStarting
                          : l10n.becomeHotspot),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: onStopHotspot,
                      icon: const Icon(Icons.wifi_tethering_off),
                      label: Text(l10n.stoppingHotspot),
                    ),
                OutlinedButton.icon(
                  onPressed: () => links!.openWifiSettings(),
                  icon: const Icon(Icons.wifi_find),
                  label: Text(l10n.joinWifi),
                ),
                OutlinedButton.icon(
                  onPressed: () => links!.openTetheringSettings(),
                  icon: const Icon(Icons.usb),
                  label: Text(l10n.tetheringSettings),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(l10n.usbHint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.45)),
          ],
        ],
      ),
    );
  }
}

/// The name and password of the hotspot this device is hosting, to be read out
/// to whoever is joining it.
class _HotspotCard extends StatelessWidget {
  const _HotspotCard({required this.hotspot});

  final HotspotCredentials hotspot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.hotspotRunning,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onPrimaryContainer)),
          const SizedBox(height: 10),
          SelectableText(
            hotspot.ssid,
            style: theme.textTheme.titleMedium?.copyWith(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            '${l10n.hotspotPassword}: ${hotspot.passphrase}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onPrimaryContainer,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The waiting end: this device is already listening on its pairing port, so
/// all that is missing is telling the user what to type on the other one.
class _ReceivePanel extends StatelessWidget {
  const _ReceivePanel({
    required this.port,
    required this.addresses,
    required this.loading,
    required this.onReload,
  });

  final int port;
  final List<LocalAddress> addresses;
  final bool loading;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.directReceiveExplain, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(l10n.yourAddresses,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.searchAgain,
              onPressed: loading ? null : onReload,
            ),
          ],
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (addresses.isEmpty)
          Text(l10n.directNoAddresses,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error))
        else
          for (final address in addresses)
            _AddressCard(address: address, port: port),
        const SizedBox(height: 16),
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(l10n.directWaiting,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ],
    );
  }
}

/// One address, big enough to read across a desk and copyable in one tap.
class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address, required this.port});

  final LocalAddress address;
  final int port;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final text = '${address.address}:$port';
    // A cable or a hotspot is the address that will work; the rest are here
    // because they might be, and are not worth the accent.
    final direct = address.kind.isDirect;

    return Padding(
      padding: const EdgeInsets.only(bottom: Layout.snug),
      child: AppCard(
        accented: direct,
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.addressCopied(text))),
            );
          }
        },
        padding: const EdgeInsets.symmetric(
            horizontal: Layout.gutter, vertical: 14),
        child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${linkLabel(l10n, address.kind)} · '
                        '${address.interfaceName}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.copy, size: 18, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// The dialling end: find the device on the link, or type where it is.
class _SendPanel extends StatelessWidget {
  const _SendPanel({
    required this.controller,
    required this.connecting,
    required this.failure,
    required this.probing,
    required this.canProbe,
    required this.found,
    required this.onProbe,
    required this.onPick,
    required this.onConnect,
    this.onCancel,
  });

  final TextEditingController controller;
  final bool connecting;
  final String? failure;
  final bool probing;
  final bool canProbe;
  final List<String>? found;
  final Future<void> Function() onProbe;
  final void Function(String address) onPick;
  final VoidCallback onConnect;

  /// Gives up on a connection still being made.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.directSendExplain, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),

        // With a link in place there is no reason to make anyone read an
        // address off the other screen: there is one other device on it.
        if (canProbe) ...[
          OutlinedButton.icon(
            onPressed: probing || connecting ? null : onProbe,
            icon: probing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.travel_explore),
            label: Text(probing ? l10n.searchingLink : l10n.findOnLink),
          ),
          if (found != null && found!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(l10n.nothingOnLink,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant)),
            ),
          for (final address in found ?? const <String>[])
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: connecting ? null : () => onPick(address),
                icon: const Icon(Icons.link),
                label: Text(address),
              ),
            ),
          const SizedBox(height: 20),
        ],

        TextField(
          controller: controller,
          autocorrect: false,
          enabled: !connecting,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => connecting ? null : onConnect(),
          decoration: InputDecoration(
            labelText: l10n.addressLabel,
            hintText: '192.168.43.1:47800',
            prefixIcon: const Icon(Icons.lan),
            border: const OutlineInputBorder(),
          ),
        ),
        if (failure != null) ...[
          const SizedBox(height: 12),
          Text(failure!,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error)),
        ],
        const SizedBox(height: 16),
        if (connecting)
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Layout.gap),
              Expanded(child: Text(l10n.directConnecting)),
              TextButton(
                onPressed: onCancel,
                child: Text(l10n.connectCancel),
              ),
            ],
          )
        else
          FilledButton.icon(
            onPressed: onConnect,
            icon: const Icon(Icons.link),
            label: Text(l10n.connect),
          ),
      ],
    );
  }
}

/// What to call a link on screen. The kind is worth more to the user than the
/// interface name: "USB cable" says what to unplug, "rndis0" does not.
String linkLabel(AppLocalizations l10n, LinkKind kind) => switch (kind) {
      LinkKind.usb => l10n.linkUsb,
      LinkKind.hotspot => l10n.linkHotspot,
      LinkKind.wifi => l10n.linkWifi,
      LinkKind.wired => l10n.linkWired,
      LinkKind.mobile => l10n.linkMobile,
      LinkKind.vpn => l10n.linkVpn,
      LinkKind.other => l10n.linkOther,
    };
