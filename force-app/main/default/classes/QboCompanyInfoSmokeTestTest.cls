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
            System.assertEquals('GET', request.getMethod());
            System.assert(request.getEndpoint().startsWith(
                'callout:QuickBooks_Sandbox/v3/company/9341458157110411/companyinfo/9341458157110411'
            ));
            System.assert(request.getEndpoint().contains('minorversion=75'));
            System.assertEquals('application/json', request.getHeader('Accept'));

            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setStatus('OK');
            response.setHeader('Content-Type', 'application/json');
            response.setBody('{"CompanyInfo":{"Id":"9341458157110411","CompanyName":"QBO Sandbox Test Company"}}');
            return response;
        }
    }
}
