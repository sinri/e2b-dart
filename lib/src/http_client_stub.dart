import 'package:http/http.dart' as http;

// Browser proxy routing is controlled by the browser/host, as in the JS SDK.
http.Client createHttpClient(String? proxy,
        {String httpVersion = '2', num? maxInFlight, num? connectionLimit}) =>
    http.Client();
