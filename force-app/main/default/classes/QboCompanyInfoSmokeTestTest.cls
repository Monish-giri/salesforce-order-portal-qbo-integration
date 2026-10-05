@IsTest
private class QboCompanyInfoSmokeTestTest {
    @IsTest
    static void runReturnsCompanyInfoResponse() {
        Test.setMock(HttpCalloutMock.class, new CompanyInfoMock());

        Test.startTest();
        QboCompanyInfoSmokeTest.SmokeTestResult result = QboCompanyInfoSmokeTest.run();
        Test.stopTest();

        System.assertEquals(200, result.statusCode);
        System.assertEquals('OK', result.status);
        System.assert(result.body.contains('"CompanyInfo"'));
    }

    private class CompanyInfoMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            QBO_Config__mdt config = QBO_Config__mdt.getInstance('Default');

            System.assertEquals('GET', request.getMethod());
            System.assert(request.getEndpoint().startsWith(
                'callout:QuickBooks_Sandbox/v3/company/'
                + EncodingUtil.urlEncode(config.Realm_Id__c, 'UTF-8')
                + '/companyinfo/'
                + EncodingUtil.urlEncode(config.Realm_Id__c, 'UTF-8')
            ));
            System.assert(request.getEndpoint().contains(
                'minorversion=' + EncodingUtil.urlEncode(config.Minor_Version__c, 'UTF-8')
            ));
            System.assertEquals('application/json', request.getHeader('Accept'));

            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"CompanyInfo":{"Id":"TEST","CompanyName":"QBO Sandbox Test Company"}}');
            return response;
        }
    }
}
