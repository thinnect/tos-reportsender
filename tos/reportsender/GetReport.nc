/**
 * @author Raido Pahtma
 * @license MIT
*/
interface GetReport {

	command uint8_t channel();

	command error_t get(uint32_t id);
	event void report(error_t result, uint32_t id, uint8_t data[], uint8_t length);

	event void newReport(uint32_t id);

}