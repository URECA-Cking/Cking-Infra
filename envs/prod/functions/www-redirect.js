function handler(event) {
  var request = event.request;
  if (request.headers.host.value !== 'www.cking.co.kr') {
    return request;
  }

  var params = [];
  for (var key in request.querystring) {
    var param = request.querystring[key];
    (param.multiValue || [param]).forEach(function (v) {
      params.push(key + '=' + v.value);
    });
  }
  var query = params.length > 0 ? '?' + params.join('&') : '';

  return {
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: { location: { value: 'https://cking.co.kr' + request.uri + query } },
  };
}
