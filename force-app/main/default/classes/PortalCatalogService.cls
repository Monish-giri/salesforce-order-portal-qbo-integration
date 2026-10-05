public with sharing class PortalCatalogService {
    private static final Integer DEFAULT_PAGE_SIZE = 24;
    private static final Integer MAX_PAGE_SIZE = 48;
    private static final String PARTNER_USER_TYPE = 'PowerPartner';

    public class CatalogProduct {
        @AuraEnabled public Id productId;
        @AuraEnabled public Id pricebookEntryId;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
        @AuraEnabled public String description;
        @AuraEnabled public String family;
        @AuraEnabled public Decimal unitPrice;

        public CatalogProduct(PricebookEntry entry) {
            productId = entry.Product2Id;
            pricebookEntryId = entry.Id;
            name = entry.Product2.Name;
            productCode = entry.Product2.ProductCode;
            description = entry.Product2.Description;
            family = entry.Product2.Family;
            unitPrice = entry.UnitPrice;
        }
    }

    public class CatalogResponse {
        @AuraEnabled public List<CatalogProduct> products;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Boolean hasMore;

        public CatalogResponse(List<CatalogProduct> products, Integer pageSize, Boolean hasMore) {
            this.products = products;
            this.pageSize = pageSize;
            this.hasMore = hasMore;
        }
    }

    @TestVisible
    private static String testPricebookDeveloperName;

    @AuraEnabled(cacheable=true)
    public static CatalogResponse getProducts(String searchTerm, Integer pageSize) {
        Integer requestedPageSize = pageSize == null ? DEFAULT_PAGE_SIZE : pageSize;
        Integer effectivePageSize = Math.max(1, Math.min(requestedPageSize, MAX_PAGE_SIZE));
        String audience = resolveAudience();
        String pricebookDeveloperName = Test.isRunningTest() && testPricebookDeveloperName != null
            ? testPricebookDeveloperName
            : resolvePricebookDeveloperName(audience);

        if (String.isBlank(pricebookDeveloperName)) {
            throw new AuraHandledException('No active catalog configuration is available for your portal audience.');
        }

        Pricebook2 configuredPricebook = getConfiguredPricebook(pricebookDeveloperName);
        if (configuredPricebook == null) {
            throw new AuraHandledException('The configured catalog pricebook could not be found or is inactive.');
        }

        String normalizedSearch = String.isBlank(searchTerm) ? null : searchTerm.trim();
        String searchPattern = normalizedSearch == null ? null : '%' + normalizedSearch + '%';

        List<PricebookEntry> entries;
        if (searchPattern == null) {
            entries = [
                SELECT Id, Product2Id, UnitPrice,
                       Product2.Name, Product2.ProductCode,
                       Product2.Description, Product2.Family
                FROM PricebookEntry
                WHERE Pricebook2Id = :configuredPricebook.Id
                  AND IsActive = true
                  AND Product2.IsActive = true
                WITH USER_MODE
                ORDER BY Product2.Name
                LIMIT :effectivePageSize
            ];
        } else {
            entries = [
                SELECT Id, Product2Id, UnitPrice,
                       Product2.Name, Product2.ProductCode,
                       Product2.Description, Product2.Family
                FROM PricebookEntry
                WHERE Pricebook2Id = :configuredPricebook.Id
                  AND IsActive = true
                  AND Product2.IsActive = true
                  AND (
                      Product2.Name LIKE :searchPattern
                      OR Product2.ProductCode LIKE :searchPattern
                  )
                WITH USER_MODE
                ORDER BY Product2.Name
                LIMIT :effectivePageSize
            ];
        }

        List<CatalogProduct> products = new List<CatalogProduct>();
        for (PricebookEntry entry : entries) {
            products.add(new CatalogProduct(entry));
        }

        return new CatalogResponse(products, effectivePageSize, entries.size() == effectivePageSize);
    }

    private static String resolveAudience() {
        return UserInfo.getUserType() == PARTNER_USER_TYPE ? 'Partner' : 'Customer';
    }

    private static String resolvePricebookDeveloperName(String audience) {
        List<Portal_Catalog_Config__mdt> configs = [
            SELECT Pricebook__c
            FROM Portal_Catalog_Config__mdt
            WHERE Audience__c = :audience
              AND Active__c = true
            ORDER BY DeveloperName
            LIMIT 1
        ];

        return configs.isEmpty() ? null : configs[0].Pricebook__c;
    }

    private static Pricebook2 getConfiguredPricebook(String developerName) {
        List<Pricebook2> pricebooks = [
            SELECT Id, Name, IsActive, DeveloperName
            FROM Pricebook2
            WHERE DeveloperName = :developerName
              AND IsActive = true
            LIMIT 1
        ];

        return pricebooks.isEmpty() ? null : pricebooks[0];
    }
}
