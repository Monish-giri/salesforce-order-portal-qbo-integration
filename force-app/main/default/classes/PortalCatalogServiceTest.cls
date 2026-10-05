@IsTest
private class PortalCatalogServiceTest {
    @TestSetup
    static void setupData() {
        Product2 product = new Product2(
            Name = 'Test Portal Product',
            ProductCode = 'TEST-001',
            Description = 'Catalog test product',
            IsActive = true
        );
        insert product;

        Id standardPricebookId = Test.getStandardPricebookId();
        Pricebook2 standardPricebook = new Pricebook2(
            Id = standardPricebookId,
            IsActive = true
        );
        update standardPricebook;

        insert new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );

        Pricebook2 portalPricebook = new Pricebook2(
            Name = 'Test Portal Catalog',
            IsActive = true
        );
        insert portalPricebook;

        insert new PricebookEntry(
            Pricebook2Id = portalPricebook.Id,
            Product2Id = product.Id,
            UnitPrice = 125,
            IsActive = true
        );
    }

    @IsTest
    static void returnsConfiguredProducts() {
        Pricebook2 portalPricebook = [
            SELECT Id, Name
            FROM Pricebook2
            WHERE Name = 'Test Portal Catalog'
            LIMIT 1
        ];

        PortalCatalogService.testPricebookName = portalPricebook.Name;

        Test.startTest();
        PortalCatalogService.CatalogResponse response =
            PortalCatalogService.getProducts(null, 24);
        Test.stopTest();

        System.assertEquals(1, response.products.size());
        System.assertEquals('Test Portal Product', response.products[0].name);
        System.assertEquals(125, response.products[0].unitPrice);
        System.assertEquals(portalPricebook.Id, [
            SELECT Pricebook2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :portalPricebook.Id
            LIMIT 1
        ].Pricebook2Id);
    }

    @IsTest
    static void filtersProductsServerSide() {
        Pricebook2 portalPricebook = [
            SELECT Id, Name
            FROM Pricebook2
            WHERE Name = 'Test Portal Catalog'
            LIMIT 1
        ];

        PortalCatalogService.testPricebookName = portalPricebook.Name;

        Test.startTest();
        PortalCatalogService.CatalogResponse response =
            PortalCatalogService.getProducts('TEST-001', 24);
        Test.stopTest();

        System.assertEquals(1, response.products.size());
        System.assertEquals('TEST-001', response.products[0].productCode);
    }

    @IsTest
    static void capsRequestedPageSize() {
        Pricebook2 portalPricebook = [
            SELECT Name
            FROM Pricebook2
            WHERE Name = 'Test Portal Catalog'
            LIMIT 1
        ];

        PortalCatalogService.testPricebookName = portalPricebook.Name;

        Test.startTest();
        PortalCatalogService.CatalogResponse response =
            PortalCatalogService.getProducts(null, 500);
        Test.stopTest();

        System.assertEquals(48, response.pageSize);
    }
}
