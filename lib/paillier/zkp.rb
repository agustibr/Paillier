
# needed for bignums
require 'set'
require 'openssl'
require 'securerandom'
require_relative 'primes'

BitStringLength = 256 #:nodoc:

module Paillier

	module ZKP

		# The ZKP class is used for performing zero-knowledge content proofs.
		# Initialization of a ZKP object generates a commitment that the user can send along with a ciphertext to another party.
		# That party can then use the commitment to confirm that the ciphertext exists in the set of pre-determined valid messages.
		class ZKP

			# Commitment generated by the ZKP object on initialization, used in ZKPVerify? function
			attr_reader :commitment

			# Ciphertext generated by the ZKP object; accessible using both myZKP.ciphertext and myZKP.cyphertext
			attr_reader :ciphertext, :cyphertext

						
			# Constructor function for a ZKP object. On initialization, generates a ZKPCommit object for use in verification
			# 
			# Example:
			# 	>> myZKP = Paillier::ZKP::ZKP.new(key, 65, [23, 38, 52, 65, 77, 94])
			#		=> [#<@p = plaintext>, #<@pubkey = <key>>, #<@ciphertext = <ciphertext>>, #<@cyphertext = <ciphertext>>, #<@commitment = <commitment>>]
			# 
			# Arguments:
			# 	public_key: The key to be used for the encryption (Paillier::PublicKey)
			# 	plaintext: The message to be encrypted (Integer)
			# 	valid_messages: The set of valid messages for encryption (Array)
			#
			# NOTE: the order of valid_messages should be the same for both prover and verifier
			def initialize(public_key, plaintext, valid_messages)
				@p = plaintext
				@pubkey = public_key
				@r, @ciphertext = Paillier.rEncrypt(@pubkey, @p)
				@cyphertext = @ciphertext
				@a_s = Array.new()
				@e_s = Array.new()
				@z_s = Array.new()
				@power = nil
				@commitment = nil

				# we generate a random value omega such that omega is coprime to n
				while( true )
					big_n = BigDecimal.new( @pubkey.n )
					@omega = Primes.generateCoprime(BigMath.log(big_n, 2).round, @pubkey.n)
					if( @omega > 0 and @omega < @pubkey.n)
						break
					end
				end
				
				# a_p = omega ^ n (mod n^2); 'a' calculation for the plaintext
				a_p = @omega.to_bn.mod_exp( @pubkey.n, @pubkey.n_sq)

				for k in (0 .. (valid_messages.size - 1)) do
					m_k = valid_messages[k]
					# g_mk = g ^ m_k (mod n^2)
					g_mk = @pubkey.g.to_bn.mod_exp(m_k.to_bn, @pubkey.n_sq)
					
					# u_k = c / g_mk (mod n^2)
					# NOTE: this is modular algebra, so u_k = c * invmod(g_mk) (mod n^2)
					u_k = @ciphertext.to_bn.mod_mul(Paillier.modInv(g_mk, @pubkey.n_sq), @pubkey.n_sq)
					unless ( @p == m_k )
						# randomly generate a coprime of n for z_k
						while( true )
							big_n = BigDecimal::new(@pubkey.n)
							z_k = Primes::generateCoprime(BigMath.log(big_n, 2).round, @pubkey.n)
							if( z_k > 0 and z_k < @pubkey.n )
								break
							end
						end
						@z_s.push(z_k.to_bn)

						# generate a random e < 2^BitStringLength
						e_k = SecureRandom.random_number((2 ** 256) - 1)
						@e_s.push(e_k.to_bn)

						# calculate z_k
						# z_nth = z^n (mod n^2)
						z_nth = z_k.to_bn.mod_exp(@pubkey.n, @pubkey.n_sq)
						# u_eth = u^e_k (mod n^2)
						u_eth = u_k.to_bn.mod_exp(e_k.to_bn, @pubkey.n_sq)
						# a_k = z_nth / u_eth (mod n^2) = z_nth * invmod(u_eth) (mod n^2)
						a_k = z_nth.to_bn.mod_mul( Paillier.modInv(u_eth, @pubkey.n_sq), @pubkey.n_sq )

						@a_s.push(a_k.to_bn)
					else
						@power = k
						@a_s.push(a_p.to_bn)
					end
				end
				# attempting to craft a ZKP object with an invalid message throws exception
				if(@power == nil)
					raise ArgumentError, "Input message does not exist in array of valid messages.", caller
				end
				# we have now generated all a_s, and all e_s and z_s, save for e_p and z_p
				# to generate e_p and z_p, we need to generate the challenge string, hash(a_s)
				# to make the proof non-interactive
				sha256 = OpenSSL::Digest::SHA256.new
				for a_k in @a_s do
					sha256 << a_k.to_s
				end
				challenge_string = sha256.digest

				# now that we have the "challenge string", we calculate e_p and z_p
				e_sum = 0.to_bn
				big_mod = 2.to_bn
				big_mod = big_mod ** 256
				for e_k in @e_s do
					e_sum = (e_sum + e_k).to_bn % big_mod
				end
				# the sum of all e_s must add up to the challenge_string
				e_p = (OpenSSL::BN.new(challenge_string.to_i) - e_sum).to_bn % big_mod
				# r_ep = r ^ e_p (mod n)
				r_ep = @r.to_bn.mod_exp(e_p.to_bn, @pubkey.n)
				# z_p = omega * r^e_p (mod n)
				z_p = @omega.to_bn.mod_mul(r_ep.to_bn, @pubkey.n)

				@e_s.insert(@power, e_p.to_bn)
				@z_s.insert(@power, z_p.to_bn)
				@commitment = ZKPCommit.new(@a_s, @e_s, @z_s)
				
			end 
		end 

		# Wrapper function that creates a ZKP object for the user.
		# Instead of needing to call Paillier::ZKP::ZKP.new(args), the user calls Paillier::ZKP.new(args).
		#
		# Example:
		# 	>> myZKP = Paillier::ZKP.new(key, 65, [23, 38, 52, 65, 77, 94])
		#		=> [#<@p = plaintext>, #<@pubkey = <key>>, #<@ciphertext = <ciphertext>>, #<@cyphertext = <ciphertext>>, #<@commitment = <commitment>>]
		# 
		# Arguments:
		# 	public_key: The key to be used for the encryption (Paillier::PublicKey)
		# 	plaintext: The message to be encrypted (Integer)
		# 	valid_messages: The set of valid messages for encryption (Array)
		#
		# NOTE: the order of valid_messages should be the same for both prover and verifier
		def self.new(pubkey, message, valid_messages)
			return Paillier::ZKP::ZKP.new(pubkey, message, valid_messages)
		end

		# Function that verifies whether a ciphertext is within the set of valid messages.
		#
		# Example:
		#
		#		>> Paillier::ZKP.verifyZKP?(key, ciphertext, [23, 38, 65, 77, 94], commitment)
		#		=> true
		#
		# Arguments:
		#		pubkey: The key used for the encryption (Paillier::PublicKey)
		#		ciphertext: The ciphertext generated using the public key (OpenSSL::BN)
		#		valid_messages: The set of valid messages for encryption (Array)
		#		commitment: The commitment generated by the prover (Paillier::ZKP::ZKPCommit)
		#
		# NOTE: the order of valid_messages should be the same for both prover and verifier
		def self.verifyZKP?(pubkey, ciphertext, valid_messages, commitment)
			u_s = Array.new
			for m_k in valid_messages do		
				# g_mk = g ^ m_k (mod n^2)
				g_mk = pubkey.g.to_bn.mod_exp(m_k.to_bn, pubkey.n_sq)
				# u_k = c / g_mk (mod n^2) = c * invmod(g_mk) (mod n^2)
				u_k = OpenSSL::BN.new(ciphertext).mod_mul( Paillier.modInv(g_mk, pubkey.n_sq), pubkey.n_sq )
				u_s.push(u_k)
			end

			# calculate the challenge_string
			sha256 = OpenSSL::Digest::SHA256.new
			for a_k in commitment.a_s do
				sha256 << a_k.to_s
			end
			challenge_string = sha256.digest

			e_sum = 0.to_bn
			big_mod = 2.to_bn
			big_mod = big_mod ** 256
			for e_k in commitment.e_s do
				e_sum = (e_sum + e_k.to_bn) % big_mod
			end
			# first we check that the sum matches correctly
			unless e_sum == OpenSSL::BN.new(challenge_string.to_i)
				return false
			end
			# then we check that z_k^n = a_k * (u_k^e_k) (mod n^2)
			for i in (0 .. (commitment.z_s.size - 1)) do
				a_k = commitment.a_s[i]
				e_k = commitment.e_s[i]
				u_k = u_s[i]
				z_k = commitment.z_s[i]
				# left hand side
				# z_kn = z_k ^ n (mod n^2)
				z_kn = z_k.to_bn.mod_exp(pubkey.n, pubkey.n_sq)
				# right hand side
				# u_ke = u_k ^ e_k (mod n^2)
				u_ke = u_k.to_bn.mod_exp(e_k, pubkey.n_sq)
				# a_kue = a_k * u_ke (mod n^2)
				a_kue = a_k.to_bn.mod_mul(u_ke, pubkey.n_sq)

				# z_k ^ n ?= a_k * (u_k ^ e_k)
				unless(z_kn == a_kue)
					return false
				end
			end
			# if it passes both tests, then we have validated the contents
			return true
		end 

		# Wrapper class used for containing the components of the ZKP commitment
		class ZKPCommit

			attr_reader :a_s, :e_s, :z_s #:nodoc:
			
			def initialize(a_s, e_s, z_s) # :nodoc:
				@a_s = a_s
				@e_s = e_s
				@z_s = z_s
			end
		
			# Serializes a commitment	
			#
			# Example:
			# 
			# 	>> myZKP = Paillier::ZKP.new(key, 65, [23, 38, 52, 65, 77, 94])
			#		=> [#<@p = plaintext>, #<@pubkey = <key>>, #<@ciphertext = <ciphertext>>, #<@cyphertext = <ciphertext>>, #<@commitment = <commitment>>]
			#		>> myZKP.commitment.to_s
			#		=> "<a1>,<a2>,<a3>,<a4>,<a5>,<a6>,;<e1>,<e2>,<e3>,<e4>,<e5>,;<z1>,<z2>,<z3>,<z4>,<z5>,"
			def to_s()
				a_s_string = ""
				e_s_string = ""
				z_s_string = ""
				for a in @a_s do
					a_s_string += a.to_s
					a_s_string += ","
				end
				for e in @e_s do
					e_s_string += e.to_s
					e_s_string += ","
				end
				for z in @z_s do
					z_s_string += z.to_s
					z_s_string += ","
				end
				return "#{a_s_string};#{e_s_string};#{z_s_string}"
			end

			# Deserializes a commitment
			#
			# Example:
			#
			#		>> commit = Paillier::ZKP::ZKPCommit.from_s(commitment_string)
			#		=> #<Paillier::ZKP::ZKPCommit: @a_s=[<a1>,<a2>, .. ,<an>], @e_s=[<e1>,<e2>, .. ,<en>], @z_s=[<z1>,<z2>, .. ,<zn>]>
			#
			# Arguments:
			#		commitment_string: Serialization of a commitment (String)
			def ZKPCommit.from_s(string)
				# these will hold the final result from string-parsing
				a_s = Array.new
				e_s = Array.new
				z_s = Array.new

				# separate at the semicolons
				a_s_string, e_s_string, z_s_string = string.split(";")

				# separate at the commas
				a_s_strings = a_s_string.split(",")
				e_s_strings = e_s_string.split(",")
				z_s_strings = z_s_string.split(",")

				# convert into arrays of bignums
				for a in a_s_strings do
					a_s.push(OpenSSL::BN.new(a))
				end
				for e in e_s_strings do
					e_s.push(OpenSSL::BN.new(e))
				end
				for z in z_s_strings do
					z_s.push(OpenSSL::BN.new(z))
				end

				# create the object with these arrays
				return ZKPCommit.new(a_s, e_s, z_s)
			end

			# == operator overload to compare two ZKP commit objects
			def ==(y) #:nodoc:
				# if the array sizes don't match return false
				if @a_s.size != y.a_s.size
					return false
				end
				if @e_s.size != y.e_s.size
					return false
				end
				if @z_s.size != y.z_s.size
					return false
				end
				# if the corresponding elements in the arrays don't math return false
				for i in (0 .. (@a_s.size - 1)) do
					if(@a_s[i] != y.a_s[i])
						return false
					end
				end
				for i in (0 .. (@e_s.size - 1)) do
					if(@e_s[i] != y.e_s[i])
						return false
					end
				end
				for i in (0 .. (@z_s.size - 1)) do
					if(@z_s[i] != y.z_s[i])
						return false
					end
				end
				# else return true
				return true
			end
		end	
	end 
end 