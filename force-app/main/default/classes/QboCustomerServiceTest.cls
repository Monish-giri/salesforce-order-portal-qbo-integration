@IsTest
private class QboCustomerServiceTest {
    @IsTest
    static void ensureCustomerUsesExistingMapping() {
        Account account = new Account(
            Name = 'Existing QBO Customer'
        );
        insert account;

        account.QBO_Customer_Id__c = '58';
        update account;

        Test.startTest();
        String qboId = QboCustomerService.ensureCustomer(account.Id);
        Test.stopTest();

        System.assertEquals('58', qboId);
    }

    @IsTest
    static void ensureCustomerFindsExistingQboCustomer() {
        Account account = new Account(
            Name = 'Find Existing Customer'
        );
        insert account;

        Test.setMock(HttpCalloutMock.class, new CustomerQueryMock());

        Test.startTest();
        String qboId = QboCustomerService.ensureCustomer(account.Id);
        Test.stopTest();

        System.assertEquals('59', qboId);

        Account refreshed = [
            SELECT QBO_Customer_Id__c
            FROM Account
            WHERE Id = :account.Id
        ];
        System.assertEquals('59', refreshed.QBO_Customer_Id__c);
    }

    @IsTest
    static void ensureCustomerCreatesQboCustomer() {
        Account account = new Account(
            Name = 'Create New Customer'
        );
        insert account;

        Test.setMock(HttpCalloutMock.class, new CustomerCreateMock());

        Test.startTest();
        String qboId = QboCustomerService.ensureCustomer(account.Id);
        Test.stopTest();

        System.assertEquals('60', qboId);

        Account refreshed = [
            SELECT QBO_Customer_Id__c
            FROM Account
            WHERE Id = :account.Id
        ];
        System.assertEquals('60', refreshed.QBO_Customer_Id__c);
    }

    private class CustomerQueryMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('GET', request.getMethod());
            System.assert(request.getEndpoint().contains('/query?'));
            System.assert(request.getEndpoint().contains('DisplayName'));
            return response(
                200,
                'OK',
                '{"QueryResponse":{"Customer":[{"Id":"59","DisplayName":"Find Existing Customer (SF-'
                + '001","CompanyName":"Find Existing Customer"}]}}'
            );
        }
    }

    private class CustomerCreateMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('POST', request.getMethod());
            System.assert(request.getEndpoint().contains('/customer?'));
            Map<String, Object> body =
                (Map<String, Object>) JSON.deserializeUntyped(request.getBody());

            System.assertEquals('Create New Customer', body.get('CompanyName'));
            System.assert(
                String.valueOf(body.get('DisplayName')).startsWith('Create New Customer (SF-')
            );

            return response(
                200,
                'OK',
                '{"Customer":{"Id":"60","DisplayName":"Create New Customer","CompanyName":"Create New Customer"}}'
            );
        }
    }

    private static HttpResponse response(Integer statusCode, String status, String body) {
        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        response.setStatus(status);
        response.setHeader('Content-Type', 'application/json');
        response.setBody(body);
        return response;
    }
}