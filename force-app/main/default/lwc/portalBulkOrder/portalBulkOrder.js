import { LightningElement, api } from 'lwc';
import getProductsByCodes from '@salesforce/apex/PortalCatalogService.getProductsByCodes';

export default class PortalBulkOrder extends LightningElement {
    @api cartItems = [];

    bulkInput = '';
    isLoading = false;
    errorMessage;
    addedLineCount = 0;
    addedQuantity = 0;

    get actionLabel() {
        return this.isLoading ? 'Building Cart...' : 'Add Bulk Order to Cart';
    }

    handleInputChange(event) {
        this.bulkInput = event.target.value;
        this.errorMessage = undefined;
        this.addedLineCount = 0;
        this.addedQuantity = 0;
    }

    handleFileChange(event) {
        const file = event.target.files?.[0];
        if (!file) {
            return;
        }

        const reader = new FileReader();
        reader.onload = () => {
            this.bulkInput = reader.result || '';
            this.errorMessage = undefined;
            this.addedLineCount = 0;
            this.addedQuantity = 0;
        };
        reader.onerror = () => {
            this.errorMessage = 'The CSV file could not be read. Please try again.';
        };
        reader.readAsText(file);
    }

    downloadTemplate() {
        const templateContent = 'Product Code,Quantity\nGC1020,25\nIN7020,10';
        const blob = new Blob([templateContent], { type: 'text/csv;charset=utf-8;' });
        const url = URL.createObjectURL(blob);
        const anchor = document.createElement('a');

        anchor.href = url;
        anchor.download = 'partner-bulk-order-template.csv';
        anchor.style.display = 'none';
        document.body.appendChild(anchor);
        anchor.click();
        document.body.removeChild(anchor);
        URL.revokeObjectURL(url);
    }

    parseInput() {
        const text = (this.bulkInput || '').trim();
        if (!text) {
            throw new Error('Enter your product codes and quantities, or upload a CSV file.');
        }

        const lines = text
            .split(/\r?\n/)
            .map(line => line.trim())
            .filter(Boolean);

        const firstLine = lines[0].toLowerCase();
        const delimiter = firstLine.includes('\t') ? '\t' : firstLine.includes(';') ? ';' : ',';
        const headerParts = firstLine
            .split(delimiter)
            .map(value => value.trim().replace(/^"|"$/g, ''));

        const codeHeaders = ['product code', 'productcode', 'code', 'sku'];
        const quantityHeaders = ['quantity', 'qty'];
        const hasHeader = headerParts.some(value => codeHeaders.includes(value))
            && headerParts.some(value => quantityHeaders.includes(value));

        let codeIndex = 0;
        let quantityIndex = 1;
        let startIndex = 0;

        if (hasHeader) {
            codeIndex = headerParts.findIndex(value => codeHeaders.includes(value));
            quantityIndex = headerParts.findIndex(value => quantityHeaders.includes(value));
            startIndex = 1;
        }

        const requested = [];

        for (let index = startIndex; index < lines.length; index += 1) {
            const parts = lines[index]
                .split(delimiter)
                .map(value => value.trim().replace(/^"|"$/g, ''));
            const code = parts[codeIndex];
            const quantity = Number(parts[quantityIndex]);

            if (!code) {
                throw new Error(`Line ${index + 1}: product code is missing.`);
            }

            if (!Number.isInteger(quantity) || quantity < 1) {
                throw new Error(`Line ${index + 1}: quantity must be a whole number greater than 0.`);
            }

            requested.push({ code, quantity });
        }

        if (!requested.length) {
            throw new Error('No order lines were found.');
        }

        return requested;
    }

    async addBulkOrderToCart() {
        if (this.isLoading) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;
        this.addedLineCount = 0;
        this.addedQuantity = 0;

        try {
            const requested = this.parseInput();
            const quantitiesByCode = new Map();

            requested.forEach(({ code, quantity }) => {
                const normalizedCode = code.trim().toUpperCase();
                quantitiesByCode.set(
                    normalizedCode,
                    (quantitiesByCode.get(normalizedCode) || 0) + quantity
                );
            });

            const codes = [...quantitiesByCode.keys()];
            const products = await getProductsByCodes({ productCodes: codes });
            const productsByCode = new Map(
                (products || []).map(product => [product.productCode?.trim().toUpperCase(), product])
            );

            const missing = codes.filter(code => !productsByCode.has(code));
            if (missing.length) {
                throw new Error(`These product codes were not found in the active Partner catalog: ${missing.join(', ')}`);
            }

            products.forEach(product => {
                const normalizedCode = product.productCode.trim().toUpperCase();
                const quantity = quantitiesByCode.get(normalizedCode);

                this.dispatchEvent(new CustomEvent('cartquantitychange', {
                    detail: {
                        productId: product.productId,
                        pricebookEntryId: product.pricebookEntryId,
                        name: product.name,
                        unitPrice: product.unitPrice,
                        recommendedRetailPrice: product.recommendedRetailPrice,
                        estimatedMarginAmount: product.estimatedMarginAmount,
                        estimatedMarginPercent: product.estimatedMarginPercent,
                        quantity
                    }
                }));
            });

            this.addedLineCount = products.length;
            this.addedQuantity = [...quantitiesByCode.values()].reduce((total, quantity) => total + quantity, 0);
            this.bulkInput = '';
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Unable to build the bulk order.';
        } finally {
            this.isLoading = false;
        }
    }
}
